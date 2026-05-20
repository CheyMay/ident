# Deployment Runbook

This runbook assumes a Linux host, Node.js 20 or newer, and a public HTTPS domain
for the integration service.

## Files and Directories

Recommended layout:

```text
/opt/ident-amocrm
  app/
  data/
  backups/
  .env
```

The service process must be able to read `.env` and write to `data/` and
`backups/`.

## Production Env

Start from the template:

```bash
cp docs/production.env.example .env
```

Set at minimum:

```bash
PUBLIC_BASE_URL=https://integration.example.ru
DATA_DIR=/opt/ident-amocrm/data
STORAGE_DRIVER=sqlite
SQLITE_FILE=/opt/ident-amocrm/data/integration.sqlite
CORS_ALLOWED_ORIGINS=https://*.amocrm.ru
IDENT_INTEGRATION_KEY=<strong-random-secret>
SERVICE_API_KEY=<strong-random-secret>
AMOCRM_BASE_URL=https://example.amocrm.ru
AMOCRM_CLIENT_ID=<client-id>
AMOCRM_CLIENT_SECRET=<client-secret>
AMOCRM_REDIRECT_URI=https://integration.example.ru/oauth/amocrm/callback
```

Use `IDENT_REQUIRE_DOCTOR_MAPPING=true` after doctors are mapped. For the first
schedule import it can stay `false` until `mappings.json` is populated.

`CORS_ALLOWED_ORIGINS` is needed only for browser requests from the amoCRM
widget. For a narrower production policy, replace the wildcard with the exact
account origin, for example `https://code9.amocrm.ru`.

## systemd

Create `/etc/systemd/system/ident-amocrm.service`:

```ini
[Unit]
Description=IDENT amoCRM integration
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/ident-amocrm/app
EnvironmentFile=/opt/ident-amocrm/.env
ExecStart=/usr/bin/node src/index.js
Restart=always
RestartSec=5
User=ident-amocrm
Group=ident-amocrm
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/ident-amocrm/data /opt/ident-amocrm/backups

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ident-amocrm
sudo systemctl status ident-amocrm
```

Logs:

```bash
journalctl -u ident-amocrm -f
```

## nginx

Minimal reverse proxy:

```nginx
server {
    listen 80;
    server_name integration.example.ru;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name integration.example.ru;

    ssl_certificate /etc/letsencrypt/live/integration.example.ru/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/integration.example.ru/privkey.pem;

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Do not redirect `POST /PostTimeTable` between paths. IDENT must reach the final
public URL directly.

## Smoke Test

Safe smoke test without booking creation:

```bash
SMOKE_BASE_URL=https://integration.example.ru \
IDENT_INTEGRATION_KEY=<ident-key> \
SERVICE_API_KEY=<service-key> \
npm run smoke
```

Booking smoke test:

```bash
SMOKE_CREATE_BOOKING=true npm run smoke
```

Use booking smoke only on a test account or when a test ticket is acceptable.

## Diagnostics

```bash
curl "https://integration.example.ru/api/diagnostics" \
  -H "X-API-Key: <service-key>"
```

The target state before enabling live data is:

- `ready=true`
- `status=ok`, or only accepted warnings
- latest IDENT timetable is present
- required amoCRM field IDs are configured
- doctor mappings cover real doctors
- no failed jobs or tickets that are not understood

## amoCRM Schema Check

After OAuth is completed, use the schema endpoint to collect real field,
pipeline, status, and catalog IDs:

```bash
curl "https://integration.example.ru/api/amocrm/schema" \
  -H "X-API-Key: <service-key>"
```

Use the response as the source of truth for these env variables:

- `AMOCRM_FIELD_*`
- `AMOCRM_PIPELINE_ID`
- `AMOCRM_STATUS_ID`
- `AMOCRM_CREATE_PIPELINE_ID`
- `AMOCRM_CREATE_STATUS_ID`
- `AMOCRM_SENT_STATUS_ID`
- `AMOCRM_FAILED_STATUS_ID`
- `AMOCRM_TIMETABLE_CATALOG_ID`
- `AMOCRM_SLOT_FIELD_*`

`bindings[*].status` should be `matched` for every ID that is required for the
enabled flow. `not_found` means the env value points to an ID that does not
exist in the connected amoCRM account.

## amoCRM Lead Dry Run

Before enabling automatic import, test a real lead:

```bash
curl "https://integration.example.ru/api/amocrm/leads/preview?id=<lead-id>" \
  -H "X-API-Key: <service-key>"
```

Expected result:

- `readyForIdent=true`
- `validation.ok=true`
- `mapping.ok=true`, or `mapping.resolved=null` only when doctor mapping is not required
- `validation.ticket` contains `ClientPhone`, client name, `DateAndTime`, and appointment time

Manual import of a known lead:

```bash
curl -X POST "https://integration.example.ru/api/amocrm/leads/import" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <service-key>" \
  -d "{\"leadId\":<lead-id>}"
```

Then check `/api/tickets?status=queued` and call `GetTickets` from IDENT or with
a controlled test request.

## State Backup

Export the full runtime state:

```bash
npm run state:export
```

The default target is `backups/state-<timestamp>.json`.

Explicit target:

```bash
STATE_EXPORT_FILE=/opt/ident-amocrm/backups/state-before-release.json \
npm run state:export
```

By default the export includes the amoCRM OAuth token, ticket queue, mappings,
latest timetable, job queue, webhook log, and slot mappings. Treat backup files
as secrets and personal data. To make a sanitized export without the OAuth token:

```bash
STATE_INCLUDE_SECRETS=false npm run state:export
```

## State Restore

Stop the service before restoring:

```bash
sudo systemctl stop ident-amocrm
```

Restore into the currently configured storage driver:

```bash
STATE_IMPORT_FILE=/opt/ident-amocrm/backups/state-before-release.json \
STATE_IMPORT_CONFIRM=YES \
npm run state:import
```

Then start and check diagnostics:

```bash
sudo systemctl start ident-amocrm
curl "https://integration.example.ru/api/diagnostics" \
  -H "X-API-Key: <service-key>"
```

The import can restore a JSON backup into SQLite or a SQLite export back into
JSON because it stores logical state keys, not raw database files.

## Release Checklist

1. Export state before deploy.
2. Deploy code.
3. Restart service.
4. Run `/health`.
5. Run `/api/diagnostics`.
6. Run `/api/amocrm/schema` after OAuth or field changes.
7. Run `/api/amocrm/leads/preview?id=<lead-id>` on a real test lead.
8. Run safe `npm run smoke`.
9. Check failed jobs and tickets.
10. Register or verify amoCRM webhooks after OAuth changes.
11. Confirm IDENT receives `GetTickets` and sends `PostTimeTable`.
