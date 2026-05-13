const baseUrl = trimSlash(process.env.SMOKE_BASE_URL || `http://127.0.0.1:${process.env.PORT || 8080}`);
const identKey = process.env.IDENT_INTEGRATION_KEY || process.env.SMOKE_IDENT_KEY || '';
const serviceApiKey = process.env.SERVICE_API_KEY || process.env.SMOKE_SERVICE_API_KEY || '';
const createBooking = ['1', 'true', 'yes', 'on'].includes(String(process.env.SMOKE_CREATE_BOOKING || '').toLowerCase());

const checks = [];

async function main() {
  await check('health', async () => {
    const response = await request('GET', '/health');
    await ensureOk(response);
    const body = await response.json();
    assert(body.ok === true, 'health.ok must be true');
    return body;
  });

  await check('diagnostics', async () => {
    const response = await request('GET', '/api/diagnostics', { serviceAuth: true });
    await ensureOk(response);
    const body = await response.json();
    assert(['ok', 'warn', 'error'].includes(body.status), 'diagnostics.status must be ok/warn/error');
    return { status: body.status, ready: body.ready, issueCodes: body.issues.map((issue) => issue.code) };
  });

  if (identKey) {
    await check('post timetable', async () => {
      const response = await request('POST', '/PostTimeTable', {
        identAuth: true,
        body: {
          Doctors: [{ Id: 900001, Name: 'Smoke Test Doctor' }],
          Branches: [{ Id: 900001, Name: 'Smoke Test Branch' }],
          Intervals: [
            {
              DoctorId: 900001,
              BranchId: 900001,
              StartDateTime: '2026-05-12T10:00:00+03:00',
              LengthInMinutes: 60,
              IsBusy: false
            }
          ]
        }
      });
      await ensureOk(response);
      return { ok: true };
    });

    await check('get tickets', async () => {
      const response = await request(
        'GET',
        '/GetTickets?dateTimeFrom=2026-05-01T00%3A00%3A00%2B03%3A00&dateTimeTo=2026-05-31T23%3A59%3A59%2B03%3A00',
        { identAuth: true }
      );
      await ensureOk(response);
      const body = await response.json();
      assert(Array.isArray(body), 'GetTickets response must be an array');
      return { tickets: body.length };
    });
  } else {
    record('post timetable', 'skipped', 'IDENT_INTEGRATION_KEY/SMOKE_IDENT_KEY is not set');
    record('get tickets', 'skipped', 'IDENT_INTEGRATION_KEY/SMOKE_IDENT_KEY is not set');
  }

  await check('mappings', async () => {
    const response = await request('GET', '/api/mappings', { serviceAuth: true });
    await ensureOk(response);
    const body = await response.json();
    return { doctors: body.doctors.length, branches: body.branches.length };
  });

  if (createBooking) {
    await check('create booking', async () => {
      const response = await request('POST', '/api/bookings', {
        serviceAuth: true,
        body: {
          id: `smoke:${Date.now()}`,
          clientFullName: 'Smoke Test Patient',
          clientPhone: '+79110001122',
          planStart: '2026-05-12T10:00:00+03:00',
          planEnd: '2026-05-12T11:00:00+03:00',
          doctorId: 900001,
          doctorName: 'Smoke Test Doctor',
          comment: 'Smoke test booking'
        }
      });
      await ensureOk(response);
      const body = await response.json();
      return { ticketId: body.ticket.Id, amoLeadId: body.amoLeadId || null };
    });
  } else {
    record('create booking', 'skipped', 'set SMOKE_CREATE_BOOKING=true to create a test ticket/lead');
  }

  await check('tickets summary', async () => {
    const response = await request('GET', '/api/tickets/summary', { serviceAuth: true });
    await ensureOk(response);
    const body = await response.json();
    return body.statuses;
  });

  await check('jobs summary', async () => {
    const response = await request('GET', '/api/jobs/summary', { serviceAuth: true });
    await ensureOk(response);
    const body = await response.json();
    return body.statuses;
  });

  printSummary();
  if (checks.some((item) => item.status === 'failed')) process.exit(1);
}

async function check(name, fn) {
  try {
    const details = await fn();
    record(name, 'passed', details);
  } catch (error) {
    record(name, 'failed', error.message);
  }
}

function record(name, status, details) {
  checks.push({ name, status, details });
}

async function request(method, path, options = {}) {
  const headers = {};
  if (options.body) headers['Content-Type'] = 'application/json';
  if (options.identAuth) headers['IDENT-Integration-Key'] = identKey;
  if (options.serviceAuth && serviceApiKey) headers['X-API-Key'] = serviceApiKey;

  return fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined
  });
}

function printSummary() {
  for (const item of checks) {
    const suffix = item.details === undefined ? '' : ` ${JSON.stringify(item.details)}`;
    console.log(`${item.status.toUpperCase()} ${item.name}${suffix}`);
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function ensureOk(response) {
  if (response.ok) return;
  throw new Error(`expected 2xx, got ${response.status}: ${await response.text()}`);
}

function trimSlash(value) {
  return String(value).replace(/\/+$/, '');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
