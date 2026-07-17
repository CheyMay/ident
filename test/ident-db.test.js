import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import test, { after, before } from 'node:test';
import { loadConfig } from '../src/config.js';
import { buildApp } from '../src/server.js';
import {
  normalizeTimetableFromIdentDbRows,
  validateReadOnlySql
} from '../src/ident/db-client.js';

const tempRoot = path.resolve('test/.tmp-ident-db');
const logger = {
  info() {},
  warn() {},
  error() {}
};

before(async () => {
  await rm(tempRoot, { recursive: true, force: true });
  await mkdir(tempRoot, { recursive: true });
});

after(async () => {
  await rm(tempRoot, { recursive: true, force: true });
});

test('validates IDENT DB SQL as read-only', () => {
  assert.equal(validateReadOnlySql('SELECT Id, Name FROM dbo.Doctors', 'doctorsSql'), 'SELECT Id, Name FROM dbo.Doctors');
  assert.throws(() => validateReadOnlySql('UPDATE dbo.Doctors SET Name = Name', 'doctorsSql'), /SELECT or WITH/i);
  assert.throws(() => validateReadOnlySql('SELECT * FROM dbo.Doctors; SELECT 1', 'doctorsSql'), /semicolons/i);
});

test('normalizes IDENT DB rows into timetable contract', () => {
  const timetable = normalizeTimetableFromIdentDbRows({
    doctors: [{ DoctorId: '10', DoctorName: 'Doctor One' }],
    branches: [{ BranchId: '2', BranchName: 'Main Branch' }],
    intervals: [
      {
        DoctorId: '10',
        BranchId: '2',
        StartDateTime: '2026-07-18T10:00:00+03:00',
        EndDateTime: '2026-07-18T10:30:00+03:00',
        IsBusy: 0
      }
    ]
  });

  assert.equal(timetable.Doctors[0].Id, 10);
  assert.equal(timetable.Branches[0].Name, 'Main Branch');
  assert.equal(timetable.Intervals[0].LengthInMinutes, 30);
  assert.equal(timetable.Summary.freeIntervals, 1);
});

test('IDENT DB endpoints expose status, mapping preview and timetable sync', async () => {
  const fakeTimetable = normalizeTimetableFromIdentDbRows({
    doctors: [{ Id: 10, Name: 'Doctor One' }],
    branches: [{ Id: 2, Name: 'Main Branch' }],
    intervals: [
      {
        DoctorId: 10,
        BranchId: 2,
        StartDateTime: '2026-07-18T10:00:00+03:00',
        LengthInMinutes: 45,
        IsBusy: false
      }
    ]
  });
  const fakeClient = {
    configured: () => true,
    summary: () => ({ enabled: true, configured: true, server: 'sql.local', database: 'IDENT', user: 'readonly_user' }),
    testConnection: async () => ({ ok: true, databaseName: 'IDENT', serverName: 'sql.local', checkedAt: '2026-07-18T00:00:00.000Z' }),
    getSchema: async () => ({
      receivedAt: '2026-07-18T00:00:00.000Z',
      summary: { tables: 1, columns: 2 },
      tables: [{ schema: 'dbo', name: 'Doctors', type: 'BASE TABLE', columns: [{ name: 'Id', type: 'int' }] }]
    }),
    getTableRows: async ({ schema, table }) => ({ schema, table, rows: [{ Id: 10, Name: 'Doctor One' }] }),
    previewTimetable: async (mapping) => ({ mapping, source: 'ident-db', timetable: fakeTimetable })
  };

  await withApp(fakeClient, async ({ baseUrl }) => {
    const statusResponse = await fetch(`${baseUrl}/api/ident-db/status`, {
      headers: { 'X-API-Key': 'service-key' }
    });
    assert.equal(statusResponse.status, 200);
    assert.equal((await statusResponse.json()).ok, true);

    const mappingResponse = await fetch(`${baseUrl}/api/ident-db/mapping`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': 'service-key' },
      body: JSON.stringify({
        doctorsSql: 'SELECT Id, Name FROM dbo.Doctors',
        branchesSql: 'SELECT Id, Name FROM dbo.Branches',
        intervalsSql: 'SELECT DoctorId, BranchId, StartDateTime, LengthInMinutes, IsBusy FROM dbo.Schedule'
      })
    });
    assert.equal(mappingResponse.status, 200);

    const previewResponse = await fetch(`${baseUrl}/api/ident-db/preview`, {
      headers: { 'X-API-Key': 'service-key' }
    });
    assert.equal(previewResponse.status, 200);
    assert.equal((await previewResponse.json()).timetable.Summary.intervals, 1);

    const syncResponse = await fetch(`${baseUrl}/api/ident-db/sync`, {
      method: 'POST',
      headers: { 'X-API-Key': 'service-key' }
    });
    assert.equal(syncResponse.status, 200);

    const timetableResponse = await fetch(`${baseUrl}/api/timetable`, {
      headers: { 'X-API-Key': 'service-key' }
    });
    const timetable = await timetableResponse.json();
    assert.equal(timetable.source, 'ident-db');
    assert.equal(timetable.Summary.doctors, 1);
  });
});

async function withApp(identDbClient, callback) {
  const dataDir = path.join(tempRoot, `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  await mkdir(dataDir, { recursive: true });
  const config = loadConfig({
    PORT: '0',
    DATA_DIR: dataDir,
    SERVICE_API_KEY: 'service-key',
    IDENT_INTEGRATION_KEY: 'test-ident-key',
    IDENT_DB_ENABLED: 'true',
    IDENT_DB_SERVER: 'sql.local',
    IDENT_DB_DATABASE: 'IDENT',
    IDENT_DB_USER: 'readonly_user',
    JOB_WORKER_ENABLED: 'false'
  });
  const app = buildApp(config, logger, { identDbClient });
  const server = createServer((req, res) => app(req, res));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    await callback({ baseUrl: `http://127.0.0.1:${port}` });
  } finally {
    await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    app.close?.();
  }
}
