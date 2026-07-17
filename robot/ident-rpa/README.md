# IDENT RPA fallback robot

This folder contains a safe baseline for a Windows desktop robot that can later
confirm amoCRM bookings in IDENT through the IDENT UI when no official write API
is available.

The robot is intentionally conservative:

- default mode is `DryRun`;
- UI clicks require both `-Execute` and `workflow.allowUnsafeExecution=true`;
- every real step can require manual `YES` confirmation;
- selectors are empty until we inspect the real IDENT window;
- logs are JSON lines for later audit.

## What this can and cannot solve

The read-only IDENT database access can give us doctors, services, schedule,
patients, and existing bookings. It cannot write an appointment back to IDENT.

This robot is the backup path:

```text
amoCRM booking -> backend ticket queue -> Windows robot -> IDENT UI -> saved appointment/request
```

It is not a replacement for an official IDENT API. It should run under a
separate clinic user so every created appointment is attributable.

## Files

- `Start-IdentRobot.ps1` - robot runner.
- `config.example.json` - safe config template.
- `tasks.sample.json` - local task for dry-run without backend access.

Use a private local config for real secrets:

```powershell
Copy-Item .\config.example.json .\config.local.json
```

Do not commit `config.local.json`.

## First local checks

Run from this folder on a Windows machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-IdentRobot.ps1 `
  -Mode DryRun `
  -ConfigPath .\config.example.json `
  -TaskFile .\tasks.sample.json
```

This validates the task format. If IDENT is not open, the command stops before
any UI action.

## Inspect IDENT UI

1. Open IDENT manually.
2. Navigate to the screen where a staff member confirms or creates a booking.
3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-IdentRobot.ps1 `
  -Mode Inspect `
  -ConfigPath .\config.local.json
```

The script exports UI Automation metadata to `inspect.outputPath`, for example:

```text
C:\ident-rpa\ui-tree.json
```

Use that file to fill selectors in `config.local.json`: `name`,
`automationId`, `className`, and `controlType`.

## Dry-run against backend

After `SERVICE_API_KEY` is set in `config.local.json`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-IdentRobot.ps1 `
  -Mode DryRun `
  -ConfigPath .\config.local.json `
  -MaxTasks 1
```

The robot reads:

```text
GET /api/tickets?status=queued
```

and prints/logs what it would place into IDENT.

## Real execution gate

Real clicking is blocked until all of these are true:

1. `config.local.json` contains real selectors from `ui-tree.json`.
2. `workflow.allowUnsafeExecution` is set to `true`.
3. The command is run with `-Mode RunOnce -Execute`.
4. If `confirmBeforeEachStep=true`, the operator types `YES` before each step.

Command:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-IdentRobot.ps1 `
  -Mode RunOnce `
  -ConfigPath .\config.local.json `
  -MaxTasks 1 `
  -Execute
```

## Questions to answer before wiring production

Ask IDENT or check on the client machine:

1. Where does a received external request appear in IDENT?
2. Can that request be converted to a normal appointment by staff?
3. Is there a stable window/screen for creating an appointment manually?
4. Does IDENT expose stable UI Automation names/automation IDs for fields?
5. Which user should the robot run under?
6. What should happen on conflict: slot busy, patient duplicate, missing doctor?
7. Should the robot confirm an existing incoming request or create a new booking
   from scratch?

## Production hardening still needed

- add a backend claim/complete endpoint so two robots cannot process the same
  ticket;
- add screenshots on failure;
- add patient duplicate resolution rules;
- add an operator-visible dashboard for failed RPA tasks;
- decide how amoCRM should be updated after the robot saves the appointment.
