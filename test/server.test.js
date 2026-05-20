import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import test, { after, before } from 'node:test';
import { loadConfig } from '../src/config.js';
import { buildApp } from '../src/server.js';

const tempRoot = path.resolve('test/.tmp');
const logger = {
  info() {},
  warn() {},
  error() {}
};

before(async () => {
  await rm(tempRoot, { recursive: true, force: true });
});

after(async () => {
  await rm(tempRoot, { recursive: true, force: true });
});

test('accepts IDENT timetable and exposes free slots', async () => {
  await withTestServer(async ({ baseUrl }) => {
    const initialDiagnosticsResponse = await fetch(`${baseUrl}/api/diagnostics`);
    assert.equal(initialDiagnosticsResponse.status, 200);
    const initialDiagnostics = await initialDiagnosticsResponse.json();
    assert.equal(initialDiagnostics.status, 'warn');
    assert.equal(
      initialDiagnostics.issues.some((issue) => issue.code === 'ident_timetable_missing'),
      true
    );

    const timetableResponse = await fetch(`${baseUrl}/PostTimeTable`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'IDENT-Integration-Key': 'test-ident-key'
      },
      body: JSON.stringify({
        Doctors: [{ Id: 2129, Name: 'Иванов Виталий Сергеевич' }],
        Branches: [{ Id: 1, Name: 'Филиал' }],
        Intervals: [
          {
            DoctorId: 2129,
            BranchId: 1,
            StartDateTime: '2026-05-12T10:00:00+03:00',
            LengthInMinutes: 60,
            IsBusy: false
          },
          {
            DoctorId: 2129,
            BranchId: 1,
            StartDateTime: '2026-05-12T11:00:00+03:00',
            LengthInMinutes: 60,
            IsBusy: true
          }
        ]
      })
    });

    assert.equal(timetableResponse.status, 200);

    const freeSlotsResponse = await fetch(`${baseUrl}/api/free-slots`);
    assert.equal(freeSlotsResponse.status, 200);
    const freeSlots = await freeSlotsResponse.json();
    assert.equal(freeSlots.Intervals.length, 1);
    assert.equal(freeSlots.Intervals[0].StartDateTime, '2026-05-12T10:00:00+03:00');

    const diagnosticsResponse = await fetch(`${baseUrl}/api/diagnostics`);
    assert.equal(diagnosticsResponse.status, 200);
    const diagnostics = await diagnosticsResponse.json();
    assert.equal(diagnostics.ident.timetable.summary.doctors, 1);
    assert.equal(diagnostics.ident.mappings.doctors, 1);
    assert.equal(
      diagnostics.issues.some((issue) => issue.code === 'ident_timetable_missing'),
      false
    );
  });
});

test('allows amoCRM widget CORS preflight and API requests', async () => {
  await withTestServer(
    async ({ baseUrl }) => {
      const preflight = await fetch(`${baseUrl}/api/diagnostics`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'https://code9.amocrm.ru',
          'Access-Control-Request-Method': 'GET',
          'Access-Control-Request-Headers': 'X-API-Key'
        }
      });

      assert.equal(preflight.status, 204);
      assert.equal(preflight.headers.get('access-control-allow-origin'), 'https://code9.amocrm.ru');
      assert.match(preflight.headers.get('access-control-allow-headers'), /X-API-Key/);

      const diagnostics = await fetch(`${baseUrl}/api/diagnostics`, {
        headers: {
          Origin: 'https://code9.amocrm.ru',
          'X-API-Key': 'service-key'
        }
      });

      assert.equal(diagnostics.status, 200);
      assert.equal(diagnostics.headers.get('access-control-allow-origin'), 'https://code9.amocrm.ru');

      const rejected = await fetch(`${baseUrl}/api/diagnostics`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'https://evil.example',
          'Access-Control-Request-Method': 'GET'
        }
      });

      assert.equal(rejected.status, 403);
      assert.equal(rejected.headers.get('access-control-allow-origin'), null);
    },
    { SERVICE_API_KEY: 'service-key' }
  );
});

test('syncs doctor mappings from timetable and resolves booking aliases', async () => {
  await withTestServer(async ({ baseUrl }) => {
    const timetableResponse = await fetch(`${baseUrl}/PostTimeTable`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'IDENT-Integration-Key': 'test-ident-key'
      },
      body: JSON.stringify({
        Doctors: [{ Id: 2129, Name: 'Doctor Official' }],
        Branches: [{ Id: 1, Name: 'Main Branch' }],
        Intervals: []
      })
    });
    assert.equal(timetableResponse.status, 200);

    const mappingResponse = await fetch(`${baseUrl}/api/mappings`);
    assert.equal(mappingResponse.status, 200);
    const mappings = await mappingResponse.json();
    assert.equal(mappings.doctors[0].identId, 2129);

    const aliasResponse = await fetch(`${baseUrl}/api/mappings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        doctors: [{ identId: 2129, identName: 'Doctor Official', aliases: ['Doc Alias'] }]
      })
    });
    assert.equal(aliasResponse.status, 200);

    const bookingResponse = await fetch(`${baseUrl}/api/bookings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        id: 'booking-mapped',
        dateAndTime: '2026-05-08T10:00:00+03:00',
        clientFullName: 'Ivan Ivanov',
        clientPhone: '+79110001122',
        planStart: '2026-05-12T10:00:00+03:00',
        doctorName: 'Doc Alias'
      })
    });
    assert.equal(bookingResponse.status, 201);

    const ticketsResponse = await fetch(
      `${baseUrl}/GetTickets?dateTimeFrom=2026-05-01T00%3A00%3A00%2B03%3A00&dateTimeTo=2026-05-31T23%3A59%3A59%2B03%3A00`,
      {
        headers: { 'IDENT-Integration-Key': 'test-ident-key' }
      }
    );
    assert.equal(ticketsResponse.status, 200);
    const tickets = await ticketsResponse.json();
    assert.equal(tickets.length, 1);
    assert.equal(tickets[0].DoctorId, 2129);
    assert.equal(tickets[0].DoctorName, 'Doctor Official');
  });
});

test('rejects booking when required doctor mapping is missing', async () => {
  await withTestServer(
    async ({ baseUrl }) => {
      const bookingResponse = await fetch(`${baseUrl}/api/bookings`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id: 'booking-unmapped',
          dateAndTime: '2026-05-08T10:00:00+03:00',
          clientFullName: 'Ivan Ivanov',
          clientPhone: '+79110001122',
          planStart: '2026-05-12T10:00:00+03:00',
          doctorName: 'Unknown Doctor'
        })
      });
      assert.equal(bookingResponse.status, 400);
      const body = await bookingResponse.json();
      assert.match(body.error, /Doctor mapping was not found/);
    },
    { IDENT_REQUIRE_DOCTOR_MAPPING: 'true' }
  );
});

test('queues booking and returns it through IDENT GetTickets', async () => {
  await withTestServer(async ({ baseUrl }) => {
    const bookingResponse = await fetch(`${baseUrl}/api/bookings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        id: 'booking-1',
        dateAndTime: '2026-05-08T10:00:00+03:00',
        clientFullName: 'Иванов Иван',
        clientPhone: '+79110001122',
        planStart: '2026-05-12T10:00:00+03:00',
        planEnd: '2026-05-12T11:00:00+03:00'
      })
    });

    assert.equal(bookingResponse.status, 201);

    const ticketsResponse = await fetch(
      `${baseUrl}/GetTickets?dateTimeFrom=2026-05-01T00%3A00%3A00%2B03%3A00&dateTimeTo=2026-05-31T23%3A59%3A59%2B03%3A00`,
      {
        headers: { 'IDENT-Integration-Key': 'test-ident-key' }
      }
    );
    assert.equal(ticketsResponse.status, 200);
    const tickets = await ticketsResponse.json();
    assert.equal(tickets.length, 1);
    assert.equal(tickets[0].Id, 'booking-1');

    const secondTicketsResponse = await fetch(
      `${baseUrl}/GetTickets?dateTimeFrom=2026-05-01T00%3A00%3A00%2B03%3A00&dateTimeTo=2026-05-31T23%3A59%3A59%2B03%3A00`,
      {
        headers: { 'IDENT-Integration-Key': 'test-ident-key' }
      }
    );
    assert.equal(secondTicketsResponse.status, 200);
    assert.deepEqual(await secondTicketsResponse.json(), []);

    const sentRecordsResponse = await fetch(`${baseUrl}/api/tickets?status=sent_to_ident`);
    assert.equal(sentRecordsResponse.status, 200);
    const sentRecords = await sentRecordsResponse.json();
    assert.equal(sentRecords.records.length, 1);
    assert.equal(sentRecords.records[0].sentCount, 1);

    const summaryResponse = await fetch(`${baseUrl}/api/tickets/summary`);
    assert.equal(summaryResponse.status, 200);
    const summary = await summaryResponse.json();
    assert.equal(summary.statuses.sent_to_ident, 1);

    const requeueResponse = await fetch(`${baseUrl}/api/tickets/requeue`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: 'booking-1' })
    });
    assert.equal(requeueResponse.status, 200);

    const requeuedTicketsResponse = await fetch(
      `${baseUrl}/GetTickets?dateTimeFrom=2026-05-01T00%3A00%3A00%2B03%3A00&dateTimeTo=2026-05-31T23%3A59%3A59%2B03%3A00`,
      {
        headers: { 'IDENT-Integration-Key': 'test-ident-key' }
      }
    );
    assert.equal(requeuedTicketsResponse.status, 200);
    const requeuedTickets = await requeuedTicketsResponse.json();
    assert.equal(requeuedTickets.length, 1);
    assert.equal(requeuedTickets[0].Id, 'booking-1');
  });
});

test('diagnostics reports failed tickets and jobs as errors', async () => {
  await withTestServer(async ({ baseUrl, dataDir }) => {
    await writeFile(
      path.join(dataDir, 'tickets.json'),
      JSON.stringify({
        records: [
          {
            id: 'ticket-failed',
            status: 'failed',
            source: 'test',
            ticket: {
              Id: 'ticket-failed',
              DateAndTime: '2026-05-08T10:00:00+03:00',
              ClientPhone: '+79110001122',
              ClientFullName: 'Ivan Ivanov'
            },
            lastError: 'broken ticket'
          }
        ]
      }),
      'utf8'
    );
    await writeFile(
      path.join(dataDir, 'jobs.json'),
      JSON.stringify({
        jobs: [
          {
            id: 'job-failed',
            type: 'amocrm.import_lead',
            status: 'failed',
            attempts: 8,
            maxAttempts: 8,
            payload: { leadId: 999 },
            lastError: 'broken job'
          }
        ]
      }),
      'utf8'
    );

    const diagnosticsResponse = await fetch(`${baseUrl}/api/diagnostics`);
    assert.equal(diagnosticsResponse.status, 200);
    const diagnostics = await diagnosticsResponse.json();

    assert.equal(diagnostics.status, 'error');
    assert.equal(diagnostics.ready, false);
    assert.equal(diagnostics.tickets.statuses.failed, 1);
    assert.equal(diagnostics.jobs.statuses.failed, 1);
    assert.equal(diagnostics.issues.some((issue) => issue.code === 'tickets_failed'), true);
    assert.equal(diagnostics.issues.some((issue) => issue.code === 'jobs_failed'), true);
  });
});

test('imports amoCRM leads into queue and sends feedback after GetTickets', async () => {
  await withMockAmoServer(async ({ baseUrl: amoBaseUrl, requests }) => {
    await withTestServer(
      async ({ baseUrl }) => {
        const ticketsResponse = await fetch(
          `${baseUrl}/GetTickets?dateTimeFrom=2026-05-01T00%3A00%3A00%2B03%3A00&dateTimeTo=2026-05-31T23%3A59%3A59%2B03%3A00`,
          {
            headers: { 'IDENT-Integration-Key': 'test-ident-key' }
          }
        );

        assert.equal(ticketsResponse.status, 200);
        const tickets = await ticketsResponse.json();
        assert.equal(tickets.length, 1);
        assert.equal(tickets[0].Id, 'amo:123');
        assert.equal(tickets[0].ClientPhone, '+79110001122');

        const jobsResponse = await fetch(`${baseUrl}/api/jobs?status=queued`);
        assert.equal(jobsResponse.status, 200);
        const jobs = await jobsResponse.json();
        assert.equal(jobs.jobs.some((job) => job.type === 'amocrm.lead_sent_feedback'), true);

        const runJobsResponse = await fetch(`${baseUrl}/api/jobs/run-due`, { method: 'POST' });
        assert.equal(runJobsResponse.status, 200);

        await waitFor(() => requests.some((request) => request.method === 'POST' && request.url === '/api/v4/leads/123/notes'));
        await waitFor(() => requests.some((request) => request.method === 'PATCH' && request.url === '/api/v4/leads/123'));

        const secondTicketsResponse = await fetch(
          `${baseUrl}/GetTickets?dateTimeFrom=2026-05-01T00%3A00%3A00%2B03%3A00&dateTimeTo=2026-05-31T23%3A59%3A59%2B03%3A00`,
          {
            headers: { 'IDENT-Integration-Key': 'test-ident-key' }
          }
        );
        assert.equal(secondTicketsResponse.status, 200);
        assert.deepEqual(await secondTicketsResponse.json(), []);
      },
      {
        AMOCRM_BASE_URL: amoBaseUrl,
        AMOCRM_ACCESS_TOKEN: 'token-1',
        AMOCRM_LONG_LIVED_TOKEN: 'true',
        AMOCRM_GETTICKETS_SOURCE: 'api',
        AMOCRM_FIELD_PLAN_START_ID: '1001',
        AMOCRM_SENT_STATUS_ID: '555',
        AMOCRM_PIPELINE_ID: '111'
      }
    );
  });
});

test('queues amoCRM webhook import jobs and processes them into tickets', async () => {
  await withMockAmoServer(async ({ baseUrl: amoBaseUrl }) => {
    await withTestServer(
      async ({ baseUrl }) => {
        const webhookResponse = await fetch(`${baseUrl}/webhooks/amocrm`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: 'leads%5Bupdate%5D%5B0%5D%5Bid%5D=123'
        });
        assert.equal(webhookResponse.status, 200);

        const jobsResponse = await fetch(`${baseUrl}/api/jobs?status=queued&type=amocrm.import_lead`);
        assert.equal(jobsResponse.status, 200);
        const jobs = await jobsResponse.json();
        assert.equal(jobs.jobs.length, 1);

        const runJobsResponse = await fetch(`${baseUrl}/api/jobs/run-due`, { method: 'POST' });
        assert.equal(runJobsResponse.status, 200);

        const ticketsResponse = await fetch(`${baseUrl}/api/tickets?status=queued`);
        assert.equal(ticketsResponse.status, 200);
        const tickets = await ticketsResponse.json();
        assert.equal(tickets.records.length, 1);
        assert.equal(tickets.records[0].id, 'amo:123');
      },
      {
        AMOCRM_BASE_URL: amoBaseUrl,
        AMOCRM_ACCESS_TOKEN: 'token-1',
        AMOCRM_LONG_LIVED_TOKEN: 'true',
        AMOCRM_FIELD_PLAN_START_ID: '1001',
        JOB_WORKER_ENABLED: 'false'
      }
    );
  });
});

test('previews and manually imports an amoCRM lead', async () => {
  await withMockAmoServer(async ({ baseUrl: amoBaseUrl }) => {
    await withTestServer(
      async ({ baseUrl }) => {
        const previewResponse = await fetch(`${baseUrl}/api/amocrm/leads/preview?id=123`);
        assert.equal(previewResponse.status, 200);
        const preview = await previewResponse.json();
        assert.equal(preview.readyForIdent, true);
        assert.equal(preview.validation.ok, true);
        assert.equal(preview.validation.ticket.Id, 'amo:123');
        assert.equal(preview.validation.ticket.ClientPhone, '+79110001122');
        assert.equal(preview.lead.contactIds[0], 456);

        const importResponse = await fetch(`${baseUrl}/api/amocrm/leads/import`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ leadId: 123 })
        });
        assert.equal(importResponse.status, 200);
        const imported = await importResponse.json();
        assert.equal(imported.queued, true);
        assert.equal(imported.ticketId, 'amo:123');
        assert.equal(imported.record.source, 'manual-import');

        const ticketsResponse = await fetch(`${baseUrl}/api/tickets?status=queued`);
        assert.equal(ticketsResponse.status, 200);
        const tickets = await ticketsResponse.json();
        assert.equal(tickets.records.length, 1);
        assert.equal(tickets.records[0].id, 'amo:123');

        const enqueueResponse = await fetch(`${baseUrl}/api/amocrm/leads/import`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ leadId: 123, runNow: false })
        });
        assert.equal(enqueueResponse.status, 202);
        const enqueued = await enqueueResponse.json();
        assert.equal(enqueued.job.type, 'amocrm.import_lead');
      },
      {
        AMOCRM_BASE_URL: amoBaseUrl,
        AMOCRM_ACCESS_TOKEN: 'token-1',
        AMOCRM_LONG_LIVED_TOKEN: 'true',
        AMOCRM_FIELD_PLAN_START_ID: '1001',
        JOB_WORKER_ENABLED: 'false'
      }
    );
  });
});

test('stores runtime amoCRM settings and uses them for lead mapping', async () => {
  await withMockAmoServer(async ({ baseUrl: amoBaseUrl }) => {
    await withTestServer(
      async ({ baseUrl }) => {
        const settingsResponse = await fetch(`${baseUrl}/api/settings/amocrm`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            amo: {
              fields: { planStart: 1001 },
              sentStatusId: 555,
              rateLimit: { minDelayMs: 1, maxRetries: 1 }
            },
            dedupe: { enabled: true, windowMinutes: 60 }
          })
        });
        assert.equal(settingsResponse.status, 200);
        const settings = await settingsResponse.json();
        assert.equal(settings.effective.amo.fields.planStart, 1001);
        assert.equal(settings.effective.amo.sentStatusId, 555);
        assert.equal(settings.effective.dedupe.enabled, true);

        const previewResponse = await fetch(`${baseUrl}/api/amocrm/leads/preview?id=123`);
        assert.equal(previewResponse.status, 200);
        const preview = await previewResponse.json();
        assert.equal(preview.validation.ticket.PlanStart, '2026-05-12T10:00:00+03:00');
        assert.equal(preview.readyForIdent, true);
      },
      {
        AMOCRM_BASE_URL: amoBaseUrl,
        AMOCRM_ACCESS_TOKEN: 'token-1',
        AMOCRM_LONG_LIVED_TOKEN: 'true'
      }
    );
  });
});

test('bootstraps amoCRM fields/statuses into runtime settings', async () => {
  await withMockAmoServer(async ({ baseUrl: amoBaseUrl }) => {
    await withTestServer(
      async ({ baseUrl }) => {
        const bootstrapResponse = await fetch(`${baseUrl}/api/amocrm/bootstrap`, { method: 'POST' });
        assert.equal(bootstrapResponse.status, 200);
        const bootstrap = await bootstrapResponse.json();
        assert.equal(bootstrap.settings.amo.pipelineId, 111);
        assert.ok(bootstrap.settings.amo.fields.planStart);
        assert.ok(bootstrap.settings.amo.fields.doctorName);
        assert.equal(bootstrap.settings.amo.sentStatusId, 555);
        assert.ok(bootstrap.settings.amo.failedStatusId);
        assert.equal(bootstrap.fields.created.some((field) => field.key === 'doctorName'), true);
        assert.equal(bootstrap.statuses.created.some((status) => status.key === 'failedStatusId'), true);
      },
      {
        AMOCRM_BASE_URL: amoBaseUrl,
        AMOCRM_ACCESS_TOKEN: 'token-1',
        AMOCRM_LONG_LIVED_TOKEN: 'true'
      }
    );
  });
});

test('ignores duplicate amoCRM tickets by phone time and doctor', async () => {
  await withMockAmoServer(async ({ baseUrl: amoBaseUrl }) => {
    await withTestServer(
      async ({ baseUrl }) => {
        const first = await fetch(`${baseUrl}/api/amocrm/leads/import`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ leadId: 123 })
        });
        assert.equal(first.status, 200);
        assert.equal((await first.json()).queued, true);

        const second = await fetch(`${baseUrl}/api/amocrm/leads/import`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ leadId: 124 })
        });
        assert.equal(second.status, 200);
        const duplicate = await second.json();
        assert.equal(duplicate.queued, false);
        assert.equal(duplicate.record.status, 'ignored');
        assert.match(duplicate.record.lastError, /Duplicate of amo:123/);

        const queuedResponse = await fetch(`${baseUrl}/api/tickets?status=queued`);
        assert.equal(queuedResponse.status, 200);
        assert.equal((await queuedResponse.json()).records.length, 1);
      },
      {
        AMOCRM_BASE_URL: amoBaseUrl,
        AMOCRM_ACCESS_TOKEN: 'token-1',
        AMOCRM_LONG_LIVED_TOKEN: 'true',
        AMOCRM_FIELD_PLAN_START_ID: '1001',
        JOB_WORKER_ENABLED: 'false'
      }
    );
  });
});

test('reports amoCRM schema and configured bindings', async () => {
  await withMockAmoServer(async ({ baseUrl: amoBaseUrl }) => {
    await withTestServer(
      async ({ baseUrl }) => {
        const schemaResponse = await fetch(`${baseUrl}/api/amocrm/schema`);
        assert.equal(schemaResponse.status, 200);
        const schema = await schemaResponse.json();

        assert.equal(schema.leadFields.some((field) => field.id === 1001), true);
        assert.equal(schema.pipelines[0].id, 111);
        assert.equal(schema.catalogs[0].id, 999);
        assert.equal(binding(schema.bindings.leadFields, 'AMOCRM_FIELD_PLAN_START_ID').status, 'matched');
        assert.equal(binding(schema.bindings.leadFields, 'AMOCRM_FIELD_DOCTOR_ID_ID').field.name, 'IDENT doctor ID');
        assert.equal(binding(schema.bindings.pipelineStatuses, 'AMOCRM_PIPELINE_ID').status, 'matched');
        assert.equal(binding(schema.bindings.pipelineStatuses, 'AMOCRM_SENT_STATUS_ID').pipelineStatus.id, 555);
        assert.equal(schema.bindings.timetableCatalog.status, 'matched');
        assert.equal(binding(schema.bindings.timetableFields, 'AMOCRM_SLOT_FIELD_IDENT_KEY_ID').status, 'matched');
        assert.deepEqual(schema.issues, []);
      },
      {
        AMOCRM_BASE_URL: amoBaseUrl,
        AMOCRM_ACCESS_TOKEN: 'token-1',
        AMOCRM_LONG_LIVED_TOKEN: 'true',
        AMOCRM_GETTICKETS_SOURCE: 'both',
        AMOCRM_FIELD_PLAN_START_ID: '1001',
        AMOCRM_FIELD_DOCTOR_ID_ID: '1003',
        AMOCRM_PIPELINE_ID: '111',
        AMOCRM_STATUS_ID: '222',
        AMOCRM_SENT_STATUS_ID: '555',
        AMOCRM_SYNC_TIMETABLE_TO_CATALOG: 'true',
        AMOCRM_TIMETABLE_CATALOG_ID: '999',
        AMOCRM_SLOT_FIELD_IDENT_KEY_ID: '2008'
      }
    );
  });
});

async function withTestServer(callback, env = {}) {
  const dataDir = path.join(tempRoot, String(Date.now()), String(Math.random()).slice(2));
  await mkdir(dataDir, { recursive: true });
  const config = loadConfig({
    PORT: '0',
    DATA_DIR: dataDir,
    IDENT_INTEGRATION_KEY: 'test-ident-key',
    ...env
  });
  const app = buildApp(config, logger);
  const server = createServer((req, res) => app(req, res));

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();

  try {
    await callback({ baseUrl: `http://127.0.0.1:${port}`, dataDir });
  } finally {
    await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    app.close?.();
    await rm(dataDir, { recursive: true, force: true });
  }
}

async function withMockAmoServer(callback) {
  const requests = [];
  let leadUpdatedAt = Math.floor(new Date('2026-05-08T07:00:00Z').getTime() / 1000);
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString('utf8');
    const url = new URL(req.url, 'http://127.0.0.1');
    requests.push({ method: req.method, url: url.pathname, query: url.search, body });

    if (req.method === 'GET' && url.pathname === '/api/v4/leads') {
      return sendMockJson(res, 200, {
        _embedded: {
          leads: [
            {
              id: 123,
              name: 'Lead 123',
              created_at: leadUpdatedAt,
              updated_at: leadUpdatedAt,
              custom_fields_values: [
                { field_id: 1001, values: [{ value: '2026-05-12T10:00:00+03:00' }] }
              ],
              _embedded: { contacts: [{ id: 456 }] }
            }
          ]
        }
      });
    }

    if (req.method === 'GET' && url.pathname === '/api/v4/leads/custom_fields') {
      return sendMockJson(res, 200, {
        _embedded: {
          custom_fields: [
            { id: 1001, name: 'Appointment start', type: 'date_time', sort: 10 },
            { id: 1002, name: 'Appointment end', type: 'date_time', sort: 20 },
            { id: 1003, name: 'IDENT doctor ID', type: 'numeric', sort: 30 }
          ]
        }
      });
    }

    if (req.method === 'GET' && url.pathname === '/api/v4/leads/pipelines') {
      return sendMockJson(res, 200, {
        _embedded: {
          pipelines: [
            {
              id: 111,
              name: 'Main pipeline',
              sort: 10,
              is_main: true,
              _embedded: {
                statuses: [
                  { id: 222, name: 'New appointment', sort: 10, pipeline_id: 111, type: 0 },
                  { id: 555, name: 'Передано в IDENT', sort: 20, pipeline_id: 111, type: 0 }
                ]
              }
            }
          ]
        }
      });
    }

    if (req.method === 'GET' && url.pathname === '/api/v4/catalogs') {
      return sendMockJson(res, 200, {
        _embedded: {
          catalogs: [{ id: 999, name: 'IDENT slots', type: 'regular', sort: 10, can_add_elements: true }]
        }
      });
    }

    if (req.method === 'GET' && url.pathname === '/api/v4/catalogs/999/custom_fields') {
      return sendMockJson(res, 200, {
        _embedded: {
          custom_fields: [
            { id: 2001, name: 'Slot start', type: 'date_time', sort: 10 },
            { id: 2008, name: 'IDENT slot key', type: 'text', sort: 80 }
          ]
        }
      });
    }

    if (req.method === 'POST' && url.pathname === '/api/v4/leads/custom_fields') {
      const fields = JSON.parse(body || '[]');
      return sendMockJson(res, 200, {
        _embedded: {
          custom_fields: fields.map((field, index) => ({
            id: 2000 + index,
            name: field.name,
            type: field.type,
            request_id: field.request_id
          }))
        }
      });
    }

    if (req.method === 'POST' && url.pathname === '/api/v4/leads/pipelines/111/statuses') {
      const statuses = JSON.parse(body || '[]');
      return sendMockJson(res, 200, {
        _embedded: {
          statuses: statuses.map((status, index) => ({
            id: 7000 + index,
            name: status.name,
            pipeline_id: 111,
            request_id: status.request_id
          }))
        }
      });
    }

    const leadMatch = url.pathname.match(/^\/api\/v4\/leads\/(\d+)$/);
    if (req.method === 'GET' && leadMatch) {
      const leadId = Number(leadMatch[1]);
      return sendMockJson(res, 200, {
        id: leadId,
        name: `Lead ${leadId}`,
        created_at: leadUpdatedAt,
        updated_at: leadUpdatedAt,
        custom_fields_values: [
          { field_id: 1001, values: [{ value: '2026-05-12T10:00:00+03:00' }] }
        ],
        _embedded: { contacts: [{ id: 456 }] }
      });
    }

    if (req.method === 'GET' && url.pathname === '/api/v4/contacts') {
      return sendMockJson(res, 200, {
        _embedded: {
          contacts: [
            {
              id: 456,
              name: 'Ivan Ivanov',
              custom_fields_values: [
                { field_code: 'PHONE', values: [{ value: '+79110001122' }] },
                { field_code: 'EMAIL', values: [{ value: 'ivan@example.ru' }] }
              ]
            }
          ]
        }
      });
    }

    if (req.method === 'POST' && url.pathname === '/api/v4/leads/123/notes') {
      return sendMockJson(res, 200, { _embedded: { notes: [{ id: 1 }] } });
    }

    if (req.method === 'PATCH' && url.pathname === '/api/v4/leads/123') {
      leadUpdatedAt += 60;
      return sendMockJson(res, 200, { id: 123 });
    }

    return sendMockJson(res, 404, { error: 'not found' });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    await callback({ baseUrl: `http://127.0.0.1:${port}`, requests });
  } finally {
    await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  }
}

function binding(bindings, env) {
  return bindings.find((item) => item.env === env);
}

function sendMockJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload)
  });
  res.end(payload);
}

async function waitFor(predicate) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < 1000) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.equal(predicate(), true);
}
