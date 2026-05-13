# IDENT amoCRM Integration

HTTP bridge for IDENT custom integrations and amoCRM.

Current scope:

- `POST /PostTimeTable` receives the schedule exported by IDENT and stores the latest snapshot.
- `GET /GetTickets` returns queued appointment requests for IDENT. When configured, it imports eligible amoCRM leads into the queue before returning data.
- `POST /api/bookings` creates a booking through this service, optionally creates an amoCRM lead, and queues the same booking for IDENT.
- `GET /oauth/amocrm/callback` completes amoCRM OAuth installation and stores tokens.
- `POST /webhooks/amocrm` receives amoCRM lead webhooks and queues changed leads for IDENT.
- Optional schedule sync from IDENT to an amoCRM catalog.

The service has no external npm dependencies.

## Requirements

- Node.js 20 or newer.
- A public HTTPS URL reachable from the IDENT administrator client.
- A random shared key configured both in IDENT and in `IDENT_INTEGRATION_KEY`.
- amoCRM private integration credentials or a long-lived token.

## Configuration

Copy `.env.example` to `.env` or provide the same variables in the hosting environment.

Minimal IDENT-only setup:

```bash
PORT=8080
IDENT_INTEGRATION_KEY=replace-with-random-secret
IDENT_REQUIRE_DOCTOR_MAPPING=false
STORAGE_DRIVER=json
```

Minimal amoCRM setup with a long-lived token:

```bash
AMOCRM_BASE_URL=https://example.amocrm.ru
AMOCRM_ACCESS_TOKEN=long-lived-token
AMOCRM_LONG_LIVED_TOKEN=true
```

OAuth refresh setup:

```bash
PUBLIC_BASE_URL=https://integration.example.ru
AMOCRM_BASE_URL=https://example.amocrm.ru
AMOCRM_CLIENT_ID=...
AMOCRM_CLIENT_SECRET=...
AMOCRM_REDIRECT_URI=https://integration.example.ru/oauth/amocrm/callback
AMOCRM_ACCESS_TOKEN=...
AMOCRM_REFRESH_TOKEN=...
AMOCRM_LONG_LIVED_TOKEN=false
```

For the OAuth install flow, set the Redirect URI in amoCRM to:

```text
https://integration.example.ru/oauth/amocrm/callback
```

To pass appointment details from amoCRM leads to IDENT, create lead custom fields and put their IDs into:

- `AMOCRM_FIELD_PLAN_START_ID`
- `AMOCRM_FIELD_PLAN_END_ID`
- `AMOCRM_FIELD_DOCTOR_ID_ID`
- `AMOCRM_FIELD_DOCTOR_AMO_ID_ID`
- `AMOCRM_FIELD_DOCTOR_NAME_ID`
- `AMOCRM_FIELD_COMMENT_ID`
- `AMOCRM_FIELD_FORM_NAME_ID`

`AMOCRM_FIELD_PLAN_START_ID` is the main field for appointment time. If `AMOCRM_FIELD_PLAN_END_ID` is empty, `AMOCRM_DEFAULT_APPOINTMENT_MINUTES` is used.

Doctor mapping:

- `PostTimeTable` automatically fills `data/mappings.json` with IDENT doctors and branches.
- If amoCRM stores the IDENT doctor ID directly, map that field to `AMOCRM_FIELD_DOCTOR_ID_ID`.
- If amoCRM stores its own doctor ID, map that field to `AMOCRM_FIELD_DOCTOR_AMO_ID_ID` and add the relation through `/api/mappings`.
- If amoCRM stores a doctor name, add aliases through `/api/mappings`.
- Set `IDENT_REQUIRE_DOCTOR_MAPPING=true` when unmapped doctors must block ticket export to IDENT.

Queue and feedback settings:

```bash
# queue: only webhook/API-created queued records
# api: fetch amoCRM leads on every GetTickets and queue changed records
# both: webhook queue plus API backfill on GetTickets
AMOCRM_GETTICKETS_SOURCE=both

# Optional amoCRM status transitions after IDENT receives a ticket.
AMOCRM_SENT_STATUS_ID=
AMOCRM_FAILED_STATUS_ID=
AMOCRM_ADD_NOTES=true
```

## Run

```bash
npm start
```

Health check:

```bash
curl http://localhost:8080/health
```

Readiness diagnostics:

```bash
curl "https://integration.example.ru/api/diagnostics" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

The response includes:

- `status`: `ok`, `warn`, or `error`.
- `ready`: false when blocking errors exist.
- `issues`: concrete configuration or runtime problems.
- IDENT timetable and mapping counters.
- amoCRM token/webhook/field status.
- ticket and job summaries.
- latest stored amoCRM webhook metadata.

## First Deployment

1. Copy a production env template:

```bash
cp docs/production.env.example .env
```

2. Fill at minimum:

```bash
PUBLIC_BASE_URL=
IDENT_INTEGRATION_KEY=
SERVICE_API_KEY=
AMOCRM_BASE_URL=
AMOCRM_CLIENT_ID=
AMOCRM_CLIENT_SECRET=
AMOCRM_REDIRECT_URI=
```

3. Start the service:

```bash
npm start
```

or with Docker:

```bash
docker compose up -d --build
```

4. Run a safe smoke test. By default it does not create a booking or amoCRM lead:

```bash
SMOKE_BASE_URL=https://integration.example.ru \
IDENT_INTEGRATION_KEY=<ident-key> \
SERVICE_API_KEY=<service-key> \
npm run smoke
```

To also create a test booking, use:

```bash
SMOKE_CREATE_BOOKING=true npm run smoke
```

Use this only on a test account or when a test lead/ticket is acceptable.

5. Complete amoCRM OAuth:

```bash
curl -H "X-API-Key: <SERVICE_API_KEY>" \
  "https://integration.example.ru/oauth/amocrm/url?mode=popup"
```

6. Register amoCRM webhooks:

```bash
curl -X POST "https://integration.example.ru/api/amocrm/webhooks/setup" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

7. Inspect amoCRM schema and verify configured field/status IDs:

```bash
curl "https://integration.example.ru/api/amocrm/schema" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

Use the returned `leadFields`, `pipelines`, `catalogs`, and `bindings` to fill
`AMOCRM_FIELD_*`, `AMOCRM_*STATUS_ID`, `AMOCRM_PIPELINE_ID`, and optional
timetable catalog variables.

8. Configure IDENT HTTP integration:

- base URL: `https://integration.example.ru`
- key: same as `IDENT_INTEGRATION_KEY`
- enable `PostTimeTable` schedule export
- enable `GetTickets` ticket import

9. After the first `PostTimeTable`, check:

```bash
curl "https://integration.example.ru/api/diagnostics" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

Resolve `issues` until `status` is `ok` or only accepted warnings remain.

For a production runbook with systemd, nginx, backup, restore, and release
checks, see [docs/deployment-runbook.md](docs/deployment-runbook.md).

## Storage

The service supports two storage drivers:

- `json`: default, keeps runtime state as files in `DATA_DIR`.
- `sqlite`: stores runtime state in one SQLite database through Node's built-in `node:sqlite`.

SQLite setup:

```bash
STORAGE_DRIVER=sqlite
SQLITE_FILE=./data/integration.sqlite
SQLITE_MIGRATE_JSON=true
```

When `SQLITE_MIGRATE_JSON=true`, existing files from `DATA_DIR` are imported on first read:

- `tickets.json`
- `timetable.json`
- `mappings.json`
- `amocrm-token.json`
- `amocrm-webhooks.json`
- `amo-slots.json`

The migration does not delete old JSON files. Keep them as backup until SQLite mode is verified. `node:sqlite` is available in the bundled Node.js 24 runtime here, but Node currently marks it as experimental, so keep `json` mode available as a rollback path.

## Background Jobs

amoCRM operations that can fail transiently are persisted as jobs and retried:

- `amocrm.import_lead`: fetch changed lead/contact after webhook and queue an IDENT ticket.
- `amocrm.lead_sent_feedback`: add note and optional status change after `GetTickets` returns a ticket.
- `amocrm.lead_failed_feedback`: add error note and optional failed status.
- `amocrm.timetable_sync`: sync latest IDENT schedule to amoCRM catalog.

Worker settings:

```bash
JOB_WORKER_ENABLED=true
JOB_WORKER_INTERVAL_MS=30000
JOB_BATCH_SIZE=10
JOB_MAX_ATTEMPTS=8
JOB_RETRY_BASE_DELAY_MS=60000
```

Diagnostics:

```bash
curl "https://integration.example.ru/api/jobs/summary" \
  -H "X-API-Key: <SERVICE_API_KEY>"

curl "https://integration.example.ru/api/jobs?status=failed" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

Manual operations:

```bash
curl -X POST "https://integration.example.ru/api/jobs/run-due" \
  -H "X-API-Key: <SERVICE_API_KEY>"

curl -X POST "https://integration.example.ru/api/jobs/retry" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <SERVICE_API_KEY>" \
  -d "{\"id\":\"<job-id>\"}"
```

## amoCRM Install

1. Configure `PUBLIC_BASE_URL`, `AMOCRM_CLIENT_ID`, `AMOCRM_CLIENT_SECRET`, and `AMOCRM_REDIRECT_URI`.
2. Start the service.
3. Open the generated install URL:

```bash
curl -H "X-API-Key: <SERVICE_API_KEY>" \
  "https://integration.example.ru/oauth/amocrm/url?mode=popup"
```

4. amoCRM redirects to `/oauth/amocrm/callback`; the service exchanges the code for access and refresh tokens and stores them in `data/amocrm-token.json`.

For a private integration where you copied an authorization code manually:

```bash
curl -X POST "https://integration.example.ru/oauth/amocrm/exchange" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <SERVICE_API_KEY>" \
  -d "{\"code\":\"...\",\"referer\":\"https://example.amocrm.ru\"}"
```

Then register amoCRM webhooks:

```bash
curl -X POST "https://integration.example.ru/api/amocrm/webhooks/setup" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

The default events are `add_lead,update_lead,status_lead`. amoCRM sends them as `application/x-www-form-urlencoded` to `/webhooks/amocrm`; the service fetches full lead/contact data through API, maps it to an IDENT ticket, and keeps it in the local queue for `GetTickets`.

When `GetTickets` returns a queued amoCRM ticket, the service marks it as `sent_to_ident`, writes a note to the lead, and optionally moves the lead to `AMOCRM_SENT_STATUS_ID`. If required fields are missing, the queue record is marked as `failed`; with `AMOCRM_FAILED_STATUS_ID` set, the lead can be moved to a separate error status.

## IDENT Setup

In IDENT integration settings, add an HTTP custom service:

- Base URL: `https://integration.example.ru`
- Serialization: JSON
- Access key: the same value as `IDENT_INTEGRATION_KEY`
- Enable schedule export if you need slots in this service.
- Enable ticket loading if you need appointment requests to flow into IDENT.

IDENT will call:

- `POST https://integration.example.ru/PostTimeTable`
- `GET https://integration.example.ru/GetTickets?dateTimeFrom=...&dateTimeTo=...&limit=...&offset=...`

Do not redirect these endpoints with HTTP 301 or 302. If a redirect is unavoidable for `PostTimeTable`, it must preserve the POST body.

## API

### `POST /api/bookings`

Creates a local ticket and, when amoCRM is configured, creates an amoCRM lead with a linked contact.

If `SERVICE_API_KEY` is set, send it as `X-API-Key`.

```json
{
  "clientFullName": "Иванов Иван",
  "clientPhone": "+79110001122",
  "clientEmail": "ivan@example.ru",
  "planStart": "2026-05-12T10:00:00+03:00",
  "planEnd": "2026-05-12T11:00:00+03:00",
  "doctorId": 2129,
  "doctorName": "Иванов Виталий Сергеевич",
  "comment": "Первичная консультация"
}
```

### `GET /api/timetable`

Returns the latest schedule snapshot received from IDENT.

### `GET /api/free-slots`

Returns only free intervals from the latest IDENT schedule export.

### `GET /api/tickets`

Returns queue records with statuses and diagnostics. Optional filter:

```bash
curl "https://integration.example.ru/api/tickets?status=failed" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

Statuses:

- `queued`: ready to be returned by `GetTickets`.
- `sent_to_ident`: already returned by `GetTickets`.
- `failed`: not enough data or processing error.
- `ignored`: reserved for future business rules.

### `GET /api/tickets/summary`

Returns queue counters and the latest failed records:

```bash
curl "https://integration.example.ru/api/tickets/summary" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

### `POST /api/tickets/requeue`

Manually returns a ticket to the `queued` state:

```bash
curl -X POST "https://integration.example.ru/api/tickets/requeue" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <SERVICE_API_KEY>" \
  -d "{\"id\":\"amo:123456\"}"
```

### `GET /api/mappings`

Returns doctor and branch dictionaries. IDENT doctors/branches are refreshed automatically from the latest `PostTimeTable`.

### `POST /api/mappings`

Merges aliases and amoCRM IDs into the mapping file:

```bash
curl -X POST "https://integration.example.ru/api/mappings" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <SERVICE_API_KEY>" \
  -d "{\"doctors\":[{\"identId\":2129,\"identName\":\"Doctor Official\",\"aliases\":[\"Doc Alias\"],\"amoIds\":[\"77\"],\"amoNames\":[\"amoCRM Doctor Name\"]}]}"
```

When a ticket is queued, the service resolves `DoctorId`/`DoctorName` against this dictionary and sends the official IDENT doctor data in `GetTickets`.

## Ticket Validation

Before a ticket is queued or returned to IDENT, the service validates the documented IDENT ticket constraints:

- `Id` is required and must be 400 characters or shorter.
- `DateAndTime` must be a valid date.
- `ClientPhone` must contain exactly one full phone number and no extra text.
- Russian mobile numbers like `9110001122` are normalized to `+79110001122`.
- Invalid local numbers like `+89110001122` are normalized to `89110001122`, because IDENT does not recognize `+89` as a country code.
- Either `ClientFullName` or separate name parts must be present, but not both.
- If both `PlanStart` and `PlanEnd` are present, start must not be later than end and duration must not exceed 12 hours.
- `DoctorId`, when present, must be an integer.

Invalid imported amoCRM tickets are marked as `failed` and can be inspected through `/api/tickets?status=failed` or `/api/tickets/summary`.

### `POST /api/amocrm/timetable/sync`

Manually syncs the latest IDENT timetable snapshot to an amoCRM catalog. This is useful if `AMOCRM_SYNC_TIMETABLE_TO_CATALOG=true` was disabled during `PostTimeTable`.

Required configuration:

```bash
AMOCRM_SYNC_TIMETABLE_TO_CATALOG=true
AMOCRM_TIMETABLE_CATALOG_ID=12345
```

Optional catalog custom field mappings:

```bash
AMOCRM_SLOT_FIELD_START_ID=
AMOCRM_SLOT_FIELD_END_ID=
AMOCRM_SLOT_FIELD_DOCTOR_ID_ID=
AMOCRM_SLOT_FIELD_DOCTOR_NAME_ID=
AMOCRM_SLOT_FIELD_BRANCH_ID_ID=
AMOCRM_SLOT_FIELD_BRANCH_NAME_ID=
AMOCRM_SLOT_FIELD_IS_BUSY_ID=
AMOCRM_SLOT_FIELD_IDENT_KEY_ID=
```

If custom field IDs are empty, the service still creates/updates catalog elements by name and stores the amoCRM element ID mapping locally in `data/amo-slots.json`.

### `GET /api/amocrm/webhooks/log`

Returns the last 200 received amoCRM webhook payloads for diagnostics.

### `GET /api/amocrm/schema`

Returns amoCRM setup metadata and checks configured environment IDs against the
real account schema:

- lead custom fields from `/api/v4/leads/custom_fields`;
- lead pipelines and statuses from `/api/v4/leads/pipelines`;
- catalogs from `/api/v4/catalogs`;
- catalog custom fields for `AMOCRM_TIMETABLE_CATALOG_ID`, when configured.

The `bindings` section maps each env variable to a status:

- `matched`: configured ID exists in amoCRM.
- `not_configured`: optional ID is empty.
- `missing`: required ID is empty.
- `not_found`: configured ID does not exist in amoCRM.

### `GET /api/amocrm/leads/preview`

Fetches one amoCRM lead, maps it to the IDENT ticket contract, applies doctor
mapping, and validates the result without changing local state.

```bash
curl "https://integration.example.ru/api/amocrm/leads/preview?id=123456" \
  -H "X-API-Key: <SERVICE_API_KEY>"
```

Use `readyForIdent`, `mapping`, and `validation.errors` to understand whether a
real lead can be exported through `GetTickets`.

### `POST /api/amocrm/leads/import`

Manually imports one amoCRM lead into the local ticket queue:

```bash
curl -X POST "https://integration.example.ru/api/amocrm/leads/import" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <SERVICE_API_KEY>" \
  -d "{\"leadId\":123456}"
```

To only enqueue the background job instead of processing immediately:

```bash
curl -X POST "https://integration.example.ru/api/amocrm/leads/import" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <SERVICE_API_KEY>" \
  -d "{\"leadId\":123456,\"runNow\":false}"
```

## Data Files

In `json` mode, runtime state is stored under `./data`:

- `timetable.json` latest IDENT schedule export.
- `tickets.json` local ticket queue with status, fingerprint, sent time, attempt count, and last error.
- `mappings.json` IDENT doctor/branch dictionaries plus amoCRM aliases and IDs.
- `amocrm-token.json` refreshed OAuth token pair.
- `amocrm-webhooks.json` recent amoCRM webhook payloads.
- `amo-slots.json` mapping between IDENT schedule slots and amoCRM catalog element IDs.
- `jobs.json` persistent retry queue for amoCRM imports, feedback, and timetable sync.

In `sqlite` mode, the same logical keys are stored in the `kv_store` table of `SQLITE_FILE`.

State backup and restore:

```bash
npm run state:export

STATE_IMPORT_FILE=./backups/state-2026-05-12T10-00-00-000Z.json \
STATE_IMPORT_CONFIRM=YES \
npm run state:import
```

Backups include runtime state and, by default, the amoCRM OAuth token. Store them
as secrets. Use `STATE_INCLUDE_SECRETS=false` when exporting a sanitized copy.

## Real Data Flow

`IDENT -> service`: IDENT periodically exports schedule to `/PostTimeTable`.

`service -> amoCRM`: if catalog sync is enabled, free slots from the latest schedule are upserted into an amoCRM catalog.

`amoCRM -> service`: amoCRM sends lead webhooks to `/webhooks/amocrm`; the service fetches lead/contact details and queues tickets. `GetTickets` can also backfill directly from amoCRM API when `AMOCRM_GETTICKETS_SOURCE=api` or `both`.

`service -> IDENT`: IDENT periodically calls `/GetTickets`; the service returns only `queued` tickets and immediately marks them as `sent_to_ident`. Ticket IDs are stable (`amo:<lead_id>`), so changed amoCRM leads are re-queued only when their mapped IDENT payload changes.

`service -> amoCRM`: after a ticket is returned to IDENT, the service enqueues a feedback job that can add a lead note and move the lead to `AMOCRM_SENT_STATUS_ID`. Failed tickets enqueue error feedback jobs for note/status updates.

## Notes From Documentation

IDENT does not expose an inbound web server. Its client periodically calls external services. For HTTP integrations, IDENT loads data with GET requests and exports data with POST requests. IDENT sends `IDENT-Integration-Key` on every request and expects non-2xx HTTP statuses for errors. Dates are ISO 8601. Schedule export uses `PostTimeTable` with `Branches`, `Doctors`, and `Intervals`; ticket loading uses `GetTickets`.

amoCRM API v4 uses `Authorization: Bearer <token>`, `/api/v4/leads` for leads, `/api/v4/leads/complex` for creating a lead with a contact, and `/oauth2/access_token` for token refresh.
