# IDENT and amoCRM Integration Notes

## IDENT Direction

IDENT runs integrations from a desktop client, usually the administrator role. The external service must be reachable by IDENT; direct inbound calls into the clinic database are not the model.

Implemented endpoints:

- `POST /PostTimeTable`: schedule export from IDENT to this service.
- `GET /GetTickets`: appointment requests from this service to IDENT.

All IDENT endpoints require `IDENT-Integration-Key`.

## Schedule Export

`PostTimeTable` accepts:

```json
{
  "Doctors": [{ "Id": 2129, "Name": "Иванов Виталий Сергеевич" }],
  "Branches": [{ "Id": 1, "Name": "Филиал" }],
  "Intervals": [
    {
      "DoctorId": 2129,
      "BranchId": 1,
      "StartDateTime": "2026-05-12T10:00:00+03:00",
      "LengthInMinutes": 60,
      "IsBusy": false
    }
  ]
}
```

The service stores the latest payload in `data/timetable.json` and exposes it through `/api/timetable` and `/api/free-slots`.

## Appointment Loading

`GetTickets` returns an array of IDENT ticket objects:

```json
[
  {
    "Id": "amo:123456",
    "DateAndTime": "2026-05-08T09:00:00+00:00",
    "ClientPhone": "+79110001122",
    "ClientFullName": "Иванов Иван",
    "PlanStart": "2026-05-12T10:00:00+03:00",
    "PlanEnd": "2026-05-12T11:00:00+03:00",
    "DoctorId": 2129,
    "DoctorName": "Иванов Виталий Сергеевич"
  }
]
```

Ticket IDs are stable:

- `amo:<lead_id>` for amoCRM leads.
- `local:<timestamp>` for bookings created while amoCRM is not configured.

Queue records are stored in `data/tickets.json`. `GetTickets` returns only `queued` tickets and then marks them as `sent_to_ident`. A ticket is re-queued automatically only when the mapped payload fingerprint changes, for example when the amoCRM lead date, phone, name, doctor, or comment changes.

Queue statuses:

- `queued`: ready for IDENT.
- `sent_to_ident`: already returned by `GetTickets`.
- `failed`: data is incomplete or invalid.
- `ignored`: duplicate or intentionally skipped record.

Duplicate protection is enabled by default. The duplicate key uses normalized
phone, appointment start time, and doctor identity/name. `IDENT_DEDUPE_WINDOW_MINUTES`
sets the time window.

Validation before export:

- `Id` is required and limited to 400 characters.
- `ClientPhone` is normalized to a single phone number without free text.
- `ClientFullName` and separate name parts are mutually exclusive.
- `PlanStart` and `PlanEnd` must be ordered correctly and cannot span more than 12 hours.
- `DoctorId` must be an integer when present.

`GET /api/tickets/summary` returns queue counters and the latest failed records.

## amoCRM Mapping

Contacts:

- `ClientPhone` comes from contact field code `PHONE`.
- `ClientEmail` comes from contact field code `EMAIL`.
- `ClientFullName` comes from contact `name`, falling back to lead `name`.

Leads:

- `PlanStart`, `PlanEnd`, doctor fields, comment, form name, and UTM fields are read from configured lead custom field IDs.
- `DateAndTime` uses `updated_at` by default so IDENT can pick up leads whose booking fields changed after creation.

The standard appointment fields and feedback statuses can be created through
`POST /api/amocrm/bootstrap`. Created/matched IDs are saved in runtime settings,
which can be inspected and edited with `GET/POST /api/settings/amocrm`.

## Doctor and Branch Dictionaries

`PostTimeTable` contains IDENT doctors and branches. The service stores them in `data/mappings.json`.

Doctor resolution order for tickets:

1. `DoctorId` from `AMOCRM_FIELD_DOCTOR_ID_ID`, if it matches an IDENT doctor.
2. amoCRM doctor ID from `AMOCRM_FIELD_DOCTOR_AMO_ID_ID`, if it is present in mapping `amoIds`.
3. doctor name from `AMOCRM_FIELD_DOCTOR_NAME_ID`, if it matches IDENT name, `aliases`, or `amoNames`.

The ticket sent to IDENT uses the official IDENT `DoctorId` and `DoctorName`. Branches are stored in mappings for diagnostics and schedule work; the documented IDENT ticket contract does not include `BranchId`.

If `IDENT_REQUIRE_DOCTOR_MAPPING=true`, unmapped doctors make the ticket invalid and the queue record becomes `failed`.

## amoCRM OAuth

Implemented endpoints:

- `GET /oauth/amocrm/url`: generates an amoCRM authorization URL with a stored CSRF state.
- `GET /oauth/amocrm/callback`: validates state, exchanges `code` for tokens, stores `accessToken`, `refreshToken`, `expiresAt`, and `baseUrl`.
- `POST /oauth/amocrm/exchange`: service-key protected manual exchange for private integrations.
- `GET /oauth/amocrm/disconnect`: validates amoCRM disconnect HMAC signature and clears stored tokens.

The redirect URI configured in amoCRM must exactly match `AMOCRM_REDIRECT_URI`.

## amoCRM Webhooks

Implemented endpoints:

- `POST /api/amocrm/webhooks/setup`: registers `PUBLIC_BASE_URL/webhooks/amocrm` in amoCRM.
- `POST /webhooks/amocrm`: receives `application/x-www-form-urlencoded` webhook payloads, extracts changed lead IDs, and persists `amocrm.import_lead` jobs.
- `GET /api/amocrm/webhooks/log`: returns the last 200 webhook payloads.

Default webhook events: `add_lead`, `update_lead`, `status_lead`.

`AMOCRM_GETTICKETS_SOURCE` controls backfill:

- `queue`: use only queued records created by webhooks or `/api/bookings`.
- `api`: fetch matching amoCRM leads during each `GetTickets`.
- `both`: use webhooks plus API backfill.

After `GetTickets` returns an amoCRM ticket, the service can add a note to the lead and move it to `AMOCRM_SENT_STATUS_ID`. If a webhook lead cannot be converted because phone or full name is missing, the queue record becomes `failed`, and the service can add an error note plus move it to `AMOCRM_FAILED_STATUS_ID`.

amoCRM API calls are paced through `AMOCRM_RATE_LIMIT_MIN_DELAY_MS` and retried
on rate-limit/transient responses according to `AMOCRM_RATE_LIMIT_MAX_RETRIES`
and `AMOCRM_RATE_LIMIT_RETRY_BASE_DELAY_MS`.

## Background Jobs

Persistent jobs are stored in `jobs.json` or SQLite key `jobs.json`.

Job types:

- `amocrm.import_lead`
- `amocrm.lead_sent_feedback`
- `amocrm.lead_failed_feedback`
- `amocrm.timetable_sync`

Jobs move through `queued`, `running`, `succeeded`, and `failed`. Failed transient jobs are retried with exponential backoff until `JOB_MAX_ATTEMPTS`. Operators can inspect `/api/jobs`, view `/api/jobs/summary`, retry a job with `/api/jobs/retry`, and manually process due jobs with `/api/jobs/run-due`.

## Diagnostics

`GET /api/diagnostics` aggregates runtime readiness in one response:

- missing `IDENT_INTEGRATION_KEY`;
- missing `SERVICE_API_KEY`;
- missing or stale IDENT timetable;
- missing doctor mappings when strict mapping is enabled;
- failed tickets;
- failed jobs;
- missing amoCRM access token;
- missing amoCRM catalog ID when timetable sync is enabled;
- missing `PUBLIC_BASE_URL` for webhook setup;
- missing amoCRM plan-start field mapping.

The endpoint returns `status=ok|warn|error`, `ready=false` for blocking errors, and summaries for IDENT, amoCRM, tickets, jobs, and webhook intake.

## Schedule Sync to amoCRM

If `AMOCRM_SYNC_TIMETABLE_TO_CATALOG=true` and `AMOCRM_TIMETABLE_CATALOG_ID` is set, the service upserts IDENT schedule intervals into an amoCRM catalog.

The mapping key is:

```text
BranchId:DoctorId:StartDateTime
```

This key is stored in `data/amo-slots.json` so later schedule exports update the same catalog elements instead of creating duplicates.

## Production Checklist

- Configure HTTPS without 301/302 redirects on `/PostTimeTable`.
- Use a strong `IDENT_INTEGRATION_KEY`.
- Set `SERVICE_API_KEY` before exposing `/api/bookings`.
- Prefer `STORAGE_DRIVER=sqlite` after the first smoke test; keep old JSON files as rollback backup.
- Create amoCRM custom fields for appointment start/end, doctor ID/name, comment, and form name.
- Or call `POST /api/amocrm/bootstrap` to create standard fields/statuses and save their IDs.
- Check `/api/mappings` after the first schedule export and add doctor aliases/amoIds through `POST /api/mappings`.
- Decide which amoCRM pipeline/status should be visible to IDENT and set `AMOCRM_PIPELINE_ID` / `AMOCRM_STATUS_ID`.
- Back up `data/amocrm-token.json`; refresh tokens are single-use.
- Register amoCRM webhooks through `/api/amocrm/webhooks/setup`.
- If schedule should be visible in amoCRM, create a regular catalog and configure `AMOCRM_TIMETABLE_CATALOG_ID`.
