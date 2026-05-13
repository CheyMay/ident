import assert from 'node:assert/strict';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import test, { after, before } from 'node:test';
import { AmoTokenStore } from '../src/amocrm/token-store.js';
import { loadConfig } from '../src/config.js';
import { createStorage, IntegrationJobQueue, TicketQueue } from '../src/storage.js';

const tempRoot = path.resolve('test/.tmp-storage');

before(async () => {
  await rm(tempRoot, { recursive: true, force: true });
});

after(async () => {
  await rm(tempRoot, { recursive: true, force: true });
});

test('sqlite storage migrates existing JSON state', async () => {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  await writeFile(
    path.join(dataDir, 'tickets.json'),
    JSON.stringify({
      records: [
        {
          id: 'ticket-1',
          status: 'queued',
          ticket: {
            Id: 'ticket-1',
            DateAndTime: '2026-05-08T10:00:00+03:00',
            ClientPhone: '+79110001122',
            ClientFullName: 'Ivan Ivanov'
          }
        }
      ]
    }),
    'utf8'
  );

  const config = loadConfig({
    DATA_DIR: dataDir,
    STORAGE_DRIVER: 'sqlite',
    SQLITE_FILE: path.join(dataDir, 'integration.sqlite')
  });
  const storage = createStorage(config, { info() {}, warn() {}, error() {} });
  const queue = new TicketQueue(storage);

  try {
    const records = await queue.listRecords();
    assert.equal(records.length, 1);
    assert.equal(records[0].id, 'ticket-1');

    await queue.markSent(['ticket-1']);
    const sent = await queue.listRecords({ status: 'sent_to_ident' });
    assert.equal(sent.length, 1);
  } finally {
    storage.close?.();
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('sqlite token store migrates legacy amoCRM token file', async () => {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  const tokenFile = path.join(dataDir, 'amocrm-token.json');
  await writeFile(
    tokenFile,
    JSON.stringify({
      accessToken: 'legacy-access',
      refreshToken: 'legacy-refresh',
      expiresAt: 123,
      baseUrl: 'https://example.amocrm.ru'
    }),
    'utf8'
  );

  const config = loadConfig({
    DATA_DIR: dataDir,
    STORAGE_DRIVER: 'sqlite',
    SQLITE_FILE: path.join(dataDir, 'integration.sqlite'),
    AMOCRM_TOKEN_FILE: tokenFile
  });
  const storage = createStorage(config, { info() {}, warn() {}, error() {} });
  const tokenStore = new AmoTokenStore(
    tokenFile,
    { accessToken: '', refreshToken: '', expiresAt: 0, baseUrl: '' },
    { storage, storageKey: 'amocrm-token.json' }
  );

  try {
    const token = await tokenStore.get();
    assert.equal(token.accessToken, 'legacy-access');

    await tokenStore.set({
      accessToken: 'stored-access',
      refreshToken: 'stored-refresh',
      expiresAt: 456,
      baseUrl: 'https://example.amocrm.ru'
    });

    const stored = await storage.readJson('amocrm-token.json', null);
    assert.equal(stored.accessToken, 'stored-access');
  } finally {
    storage.close?.();
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('job queue retries failed jobs with backoff and manual retry', async () => {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  const config = loadConfig({ DATA_DIR: dataDir });
  const storage = createStorage(config, { info() {}, warn() {}, error() {} });
  const jobs = new IntegrationJobQueue(storage);

  try {
    const job = await jobs.enqueue('test.job', { value: 1 }, { maxAttempts: 2 });
    const running = await jobs.markRunning(job.id);
    assert.equal(running.attempts, 1);

    const retried = await jobs.fail(job.id, new Error('temporary'), 1000);
    assert.equal(retried.status, 'queued');
    assert.equal(retried.lastError, 'temporary');

    const rerun = await jobs.markRunning(job.id);
    assert.equal(rerun.attempts, 2);
    const failed = await jobs.fail(job.id, new Error('permanent'), 1000);
    assert.equal(failed.status, 'failed');

    const manual = await jobs.retry(job.id);
    assert.equal(manual.status, 'queued');
    assert.equal(manual.lastError, null);
  } finally {
    storage.close?.();
    await rm(dataDir, { recursive: true, force: true });
  }
});
