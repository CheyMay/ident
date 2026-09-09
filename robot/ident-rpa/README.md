# IDENT RPA fallback robot

This folder contains a safe baseline for a Windows desktop robot that can later
confirm amoCRM bookings in IDENT through the IDENT UI when no official write API
is available.

The robot is intentionally conservative:

- default mode is `DryRun`;
- UI clicks require both `-Execute` and `workflow.allowUnsafeExecution=true`;
- every real step can require manual `YES` confirmation;
- selectors are empty until we inspect the real IDENT window;
- real execution must finish with a configured UI success condition;
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
- `Start-IdentTraining.ps1` - passive multi-screen observation window, no UI writes.
- `RobotCapture.ps1` - fresh-capture validation, isolated child lifetime and explicit private archive.
- `RobotSafety.ps1` - observation/execution leases and explicit patient-name contracts.
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

For a short supervised clinic session, use **Начать показ экранов** in desktop
2.14.0. After consent to local UI-text capture, press Ctrl+Alt+F8 while IDENT is
foreground at each relevant state: calendar, slot menu, blank appointment,
selected patient, date/time settings. Wait for completion before changing state.
Finish with **Завершить и собрать архив**. No shell commands are needed.

Capture is bounded to one scanner, 60 seconds per attempt, 12 attempts and 15
minutes per session. Successful states remain separate; exports revalidate each
ID/time/hash. The private ZIP allowlists only UI trees, technical summaries and
a session index. It excludes configuration, credentials, logs and screenshots;
the UI trees themselves can contain personal data. No automatic upload occurs.

Observation takes an exclusive file lease. Worker and robot execution share read
leases, so observation cannot start during a write and no ticket is claimed
during observation. The kernel releases handles after process termination; the
lock file is never a stale flag to delete. Both worker and robot must be updated.
Each scanner is attached to a Windows Job with KillOnJobClose. A crash of its
owner ends that scanner; ordinary timeouts are also enforced by the parent.

The alternate `calibration-split-candidate.json` uses `patientNameMode: split`
and requires explicit ClientSurname, ClientName, ClientPatronymic. The patronymic
may be an explicit empty string. The robot does not split or reorder FullName.
Each part has its own set-and-readback step; the original profile remains intact
and the candidate cannot execute. Existing FullName-only amoCRM tickets need a
separate form/backend contract adjustment, not a guess in the robot. Patient
selection/creation and calendar navigation still need a real clinic adapter.

For clinic operators, use the desktop's **Проверить окно IDENT** button. It starts
after eight seconds, is bounded by a one-minute parent timeout, and does not
activate the robot. **Скопировать скан** accepts only the current run ID, timestamp,
schema and matching file hash. The UI no longer opens the legacy Inspect console
or forces IDENT to lose focus after scanning.

The low-level Inspect command below remains a developer tool; its static output
file is not evidence of a fresh desktop capture. Calibrate produces timestamped
files and reports `ROBOT_CAPTURE_OK`, not a verified booking profile. A visible
top-level New Appointment dialog is scanned before the large underlying calendar.
Separate surname/given-name/patronymic roles are reported for adapter development;
they do not make the full-name workflow compatible with a split-name form.

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

`Calibrate` captures one screen and writes a **candidate**, never an executable
profile. Capture the calendar, its appointment context menu, and the new
appointment dialog separately. The clinic build may not expose these controls
through UI Automation; a screenshot is not a substitute for that inspection.
The shipped workflow is a template, not a tested IDENT navigation adapter.

Unattended execution requires a separately verified local profile, exactly one
final save, writable/read-back patient, doctor, start and **end** fields, and a
positive success indicator absent before execution and present after saving.
`valueFormat` on start/end steps may format clinic wall time (for example
`dd.MM.yyyy HH:mm`) without converting to the workstation timezone.
Dialogs merely disappearing are not accepted as confirmation.

`execution-pending.json` is written before touching IDENT. An interrupted run
requires operator review; never delete this marker to blindly force a retry.
After verified success a durable outbox marker lets the agent retry only the
server acknowledgement, including after a restart or an expired backend lease.

UI actions can block in the application provider even when the action is normally
asynchronous: [Microsoft InvokePattern documentation](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.invokepattern.invoke?view=netframework-4.8.1).
The worker bounds the child process and the desktop bounds capture separately.

Real clicking is blocked until all of these are true:

1. `config.local.json` contains real selectors from `ui-tree.json`.
2. `workflow.allowUnsafeExecution` is set to `true`.
3. `workflow.successCondition` points to a selector that confirms the save.
4. The command is run with `-Mode RunOnce -Execute`.
5. If `confirmBeforeEachStep=true`, the operator types `YES` before each step.

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

The unified desktop worker uses backend claim/complete endpoints, prevents HTTP
`GetTickets` and robot delivery from running at the same time, and stores a
local non-patient receipt after a verified UI save. If the server response is
lost, the same task is acknowledged later without repeating the UI actions.

## Production hardening still needed

- add screenshots on failure;
- add patient duplicate resolution rules;
- add an operator-visible dashboard for failed RPA tasks;
- decide how amoCRM should be updated after the robot saves the appointment.
