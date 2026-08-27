import assert from 'node:assert/strict';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import test, { after, before } from 'node:test';
import { AmoTokenStore } from '../src/amocrm/token-store.js';
import { loadConfig } from '../src/config.js';
import {
  AgentSchemaStore,
  AgentStatusStore,
  createStorage,
  IntegrationJobQueue,
  TicketQueue
} from '../src/storage.js';

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

test('ticket cancellation is idempotent and releases its reservation', async () => {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  const config = loadConfig({ DATA_DIR: dataDir });
  const storage = createStorage(config, { info() {}, warn() {}, error() {} });
  const queue = new TicketQueue(storage, { timetableMaxAgeMinutes: 30, reservationMinutes: 720 });
  const timetable = {
    receivedAt: new Date().toISOString(),
    Doctors: [{ Id: 10, Name: 'Doctor' }],
    Branches: [{ Id: 20, Name: 'Clinic' }],
    Intervals: [{
      DoctorId: 10,
      BranchId: 20,
      StartDateTime: '2026-09-01T10:00:00+03:00',
      LengthInMinutes: 15,
      IsBusy: false
    }]
  };
  const ticket = {
    Id: 'cancel-1',
    DoctorId: 10,
    PlanStart: '2026-09-01T10:00:00+03:00',
    PlanEnd: '2026-09-01T10:15:00+03:00'
  };

  try {
    await queue.reserveAndUpsert(ticket, { status: 'queued' }, { timetable, branchId: 20 });
    const canceled = await queue.cancel(ticket.Id, 'operator cleanup');
    assert.equal(canceled.status, 'ignored');
    assert.equal(canceled.canceled, true);
    assert.equal(canceled.changed, true);
    assert.equal(canceled.reservation.status, 'released');
    assert.equal(canceled.reservation.releaseReason, 'cancelled');
    assert.equal(await queue.claimForRobot('clinic-agent', 300, timetable), null);

    const repeated = await queue.cancel(ticket.Id, 'second request');
    assert.equal(repeated.canceled, true);
    assert.equal(repeated.changed, false);
  } finally {
    storage.close?.();
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('robot failure keeps the slot quarantined for operator review', async () => {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  const config = loadConfig({ DATA_DIR: dataDir });
  const storage = createStorage(config, { info() {}, warn() {}, error() {} });
  const queue = new TicketQueue(storage, {
    timetableMaxAgeMinutes: 30,
    reservationMinutes: 720,
    robotFailureHoldMinutes: 60
  });
  const timetable = {
    receivedAt: new Date().toISOString(),
    Doctors: [{ Id: 10, Name: 'Doctor' }],
    Branches: [{ Id: 20, Name: 'Clinic' }],
    Intervals: [0, 15, 30].map((minute) => ({
      DoctorId: 10,
      BranchId: 20,
      StartDateTime: `2026-09-01T10:${String(minute).padStart(2, '0')}:00+03:00`,
      LengthInMinutes: 15,
      IsBusy: false
    }))
  };
  const ticket = {
    Id: 'robot-review-1',
    DoctorId: 10,
    PlanStart: '2026-09-01T10:00:00+03:00',
    PlanEnd: '2026-09-01T10:45:00+03:00'
  };

  try {
    await queue.reserveAndUpsert(ticket, { status: 'queued' }, { timetable, branchId: 20 });
    const claimed = await queue.claimForRobot('clinic-agent', 300, timetable);
    assert.equal(claimed.status, 'robot_processing');
    await queue.failRobot(ticket.Id, 'clinic-agent', 'selector not found');

    const [record] = await queue.listRecords({ status: 'robot_failed' });
    assert.equal(record.reservation.status, 'awaiting_review');
    assert.equal((await queue.timetableWithReservations(timetable)).Intervals.filter((item) => item.IsReserved).length, 3);
    const summary = await queue.summary();
    assert.equal(summary.statuses.robot_failed, 1);
    assert.equal(summary.failed[0].id, ticket.Id);
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('queue summary reports expired robot leases', async () => {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  const config = loadConfig({ DATA_DIR: dataDir });
  const storage = createStorage(config, { info() {}, warn() {}, error() {} });
  const queue = new TicketQueue(storage);

  try {
    await storage.writeJson('tickets.json', {
      records: [{
        id: 'expired-lease',
        status: 'robot_processing',
        robotLeaseUntil: '2020-01-01T00:00:00.000Z',
        ticket: { Id: 'expired-lease' }
      }]
    });
    assert.equal((await queue.summary()).staleRobotClaims, 1);
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('robot delivery mode requires an online calibrated agent', async () => {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  const config = loadConfig({ DATA_DIR: dataDir });
  const storage = createStorage(config, { info() {}, warn() {}, error() {} });
  const agents = new AgentStatusStore(storage, 30);

  try {
    await agents.heartbeat({
      agentId: 'clinic-1',
      robot: { enabled: false, configured: true, state: 'idle' }
    });
    await agents.setDesired('clinic-1', { robotEnabled: true });
    assert.equal(await agents.hasRobotModeEnabled(), true);
    assert.equal(await agents.isRobotModeEnabled('clinic-1'), true);

    const data = await storage.readJson('agents.json', null);
    data.agents['clinic-1'].lastSeenAt = '2020-01-01T00:00:00.000Z';
    await storage.writeJson('agents.json', data);
    assert.equal(await agents.hasRobotModeEnabled(), false);
  } finally {
    storage.close?.();
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('stores clinic agent schema metadata without row data', async () => {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  const config = loadConfig({ DATA_DIR: dataDir, STORAGE_DRIVER: 'sqlite', SQLITE_FILE: path.join(dataDir, 'state.sqlite') });
  const storage = createStorage(config, { info() {}, warn() {}, error() {} });
  const schemas = new AgentSchemaStore(storage);

  try {
    const stored = await schemas.put('clinic-1', {
      generatedAt: '2026-07-30T10:00:00Z',
      server: '192.168.0.3',
      database: 'IDENT',
      tables: [{
        schema: 'dbo',
        name: 'Doctors',
        type: 'BASE TABLE',
        columns: [{ position: 1, name: 'Id', type: 'int', nullable: false }]
      }]
    });
    assert.deepEqual(stored.summary, { tables: 1, columns: 1 });
    const loaded = await schemas.get('clinic-1');
    assert.equal(loaded.tables[0].name, 'Doctors');
    assert.equal(Object.hasOwn(loaded.tables[0], 'rows'), false);
  } finally {
    storage.close?.();
    await rm(dataDir, { recursive: true, force: true });
  }
});
