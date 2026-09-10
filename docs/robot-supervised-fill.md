# Supervised Patient-Form Fill

## Release Boundary

Current clinic check (2026-09-10): this stage is included in installed agent
2.14.10. Preview passed on the expanded form for 2026-09-24, 09:00-09:30.
The operator-confirmed fill stopped with `partial / FILL_FORM_CHANGED`,
`WriteAttempts=1`, `Written=0`, `Skipped=1`, `SaveInvoked=false`, and
`RequiresManualReview=true`. The matching surname was skipped; the next role
was first name. The old report does not establish whether its setter ran:
the attempt counter increments before the writer's final guard.

The operator reported the form closed itself later and no appointment appeared
in the calendar. A subsequent surname search showed only the old card #16;
no new card was visible. IDENT's toolbar also showed an unfinished draft with
the test first name. Neither screenshot proves which UIA guard failed.
Keep `fill-check-pending.json` and the run report; do not rerun, delete evidence,
or enable the queue based only on an empty calendar. The form closure is not
proven to be the cause of the earlier rejection.

Additional failure diagnostics are included in 2.14.11, now installed as
confirmed below. `WriteReturned` counts completed writer callbacks;
`FailurePhase`, `FailureRole`, and `FailureReason` distinguish a pre-set guard
from failed readback, using fixed labels only. They do not capture field values,
window text, provider messages, phone numbers, or runtime identities. No guard
was relaxed, retries added, or old pending receipt cleared. These diagnostics
cannot retrospectively identify the clinic failure and are not its verified fix.
Sequential checks passed: FillCheck, FillRuntime, FillLauncher, PatientForm,
and RobotSafety. The new fixtures reproduce the old report's identical counters
both before a setter and after a returned setter; neither fixture proves which
case occurred in IDENT.

## Read-Only Change Observation (2.14.11)

Published and assigned only to `stomazub-laptop-7osrm534` on 2026-09-10 at
16:44:47 UTC after a fresh online, disabled-robot, idle-capture gate. Rollback
assignment metadata is retained in the private local admin directory. Agent
heartbeat at 16:45:47 UTC reported 2.14.11; diagnostics received at 16:46:50 UTC
confirmed `succeeded`, worker task `Running`, robot disabled, schedule `ok`.
The supervisor hash matches the previously verified 2.14.10 lifecycle module.
The subsequent clinic observation is recorded below. No queue was enabled.

- Remote release: `ident-agent-release-2.14.11.zip`, 103409 bytes,
  SHA256 `649A2F3D8B62DAE07752F4973A907B4EF724477B0A9F01653312C21C99CEDD64`.
- Client installer: `ident-desktop-2.14.11.zip`, 111004 bytes,
  SHA256 `4C6FF966F8D4C42B6F179298D9F8C502B5F4338F18EABCC8BE5457FE47F301D8`.
- Sequential PS5 checks passed: FillObservation, FillCheck, FillRuntime,
  FillLauncher, PatientForm, RobotSafety, InstallerPackage, AgentUpdate.
  Update and rollback fixtures preserve the pending receipt byte-for-byte.
  Archive source comparison, syntax/BOM checks and Git whitespace checks passed.
  The published 2.14.10 archive was not modified.

### Clinic Observation Result

On 2026-09-10 the operator supplied a screenshot of the 2.14.11 read-only
observation result: `Ok=true`, `State=observed_change`, `BaselineCaptured=true`,
14 accepted snapshots and 4 samples discarded for input activity. Only
`patientFirstNameInput` appears in `ValueChangedRoles`;
`ExpectedFirstNameObserved=true`. Identity and bounds change lists are empty.
All write counters are zero, `SaveInvoked=false`, and no failure is reported.
These observations concern accepted snapshots only; they do not rule out
transient changes between samples or explain the old automatic-fill failure.

The operator could not hear the ready sound through AnyDesk and counted time
manually. The result is usable because the blank baseline was captured and the
expected name was subsequently observed. Do not repeat this successful read-only
check just for timing. Future checks must use the visible ready marker below,
not a guessed delay. Manual-review and unattended-readiness flags intentionally
remain `true` and `false`; observation does not approve another write. The test
draft still needs explicit operator review; retain the old pending receipt.

The next clinic check uses `-ObserveChanges`, **not `-Execute`**. These switches
are mutually exclusive at the launcher, child, and runtime entry points.
Keep the previous `fill-check-pending.json` and reports. Observation accepts
that receipt without changing it; another execution remains blocked.

1. Open the matching expanded new-patient form manually with surname present,
   first name empty, and appointment notifications off. Do not save.
2. Position PowerShell so its output is visible without switching away from IDENT.
   Run the bounded launcher with the private preview request and `-ObserveChanges`.
   Activate IDENT within eight seconds and wait without typing for the visible
   `IDENT_OBSERVATION_READY` marker. Sound is optional, not a reliable AnyDesk cue.
3. After the marker, manually enter only the agreed first name; keep IDENT active
   and wait about 30 seconds. If readiness is not visible, do not guess or save;
   wait for the result. UIA delays remain bounded by the launcher's 180-second limit.
4. Inspect the new run's `result.json`, not the old pending run. The result lists
   only fixed role names for value, identity, and geometry changes, plus counters
   and sanitized failure details. No field text, IDs, coordinates, or provider
   exceptions are exported. `no_change` is not a successful fill test.

Observation has no writer or journal callback. Manual typing is permitted between
read-only samples; a sample interrupted by input is discarded. Foreground HWND,
PID, root identity, appointment context, notification state, installation guards,
interaction lease, and timeout remain enforced. Writer guards are unchanged.
Observation never grants readiness for unattended use, invokes Save, or removes
the manual-review requirement. IDENT may still internally process the operator's
manual edits. It is not a verified fix for the original failure.

### Original Development Record

Local candidate 2.14.9, not published or assigned to the clinic. No remote
configuration, schedule, queue ticket or patient record was changed while
developing this stage. Last observed clinic version was 2.14.7, robot disabled,
on 2026-09-09 at 18:18:20 UTC; this is not a fresh health check.

This is a specialist-operated test, not the client's finished one-button
booking workflow. It requires an already-open **expanded new-patient form**.
It does not select/create a patient, open the calendar, drag/split intervals,
click Save, mark a ticket confirmed, or enable automatic queue processing.
IDENT itself may process field changes; absence of a Save click is not a
guarantee that IDENT performs no internal persistence.

## Guards

- Default is preview: values are checked but never entered.
- Execution requires `-Execute` and a separate on-screen confirmation showing
  the exact proposed test data; No is the default answer.
- Agent robot feature must be explicitly disabled. Existing unconfirmed real
  execution or a previous fill-test receipt blocks another execution.
- An exclusive interaction lease and execution mutex prevent concurrent scans,
  training and queue execution while the test runs.
- Exact foreground HWND, PID, root RuntimeId and physical last-input tick are
  guarded. Locking Windows, switching windows or resuming input stops the test.
- Each field is resolved from a fresh scoped UIA tree; the expanded layout,
  doctor caption, date/start/end, enabled/writable fields and identities must
  match. Appointment notifications must be verifiably off, never auto-toggled.
- Different existing values are not overwritten. Empty/masked placeholders
  can be filled; already matching values are skipped. Phone and DOB readback
  are normalized only by their narrow supported formats.
- Every SetValue is preceded by another fresh check and a persistent write-intent
  receipt. Readback verifies all six fields; unexpected autofill also stops.
  There is no retry, rollback, keyboard fallback or save-button invocation.
- A hidden child is attached to a kill-on-close job before an arm handshake.
  A 180-second overall limit includes confirmation, delay and UIA work. Timeout
  terminates the test child, never IDENT or the agent. Partial forms remain
  for inspection, and manual-review evidence is retained.
- Reports contain fixed status/error codes and counters, not patient values or
  provider exception details. No test data is sent to the backend.

Live read/check/write calls are not an atomic transaction with IDENT. These
guards reduce risk but cannot prove behavior of an untested UIA provider or
detect a semantically different anonymous field with identical geometry.
Supervised visual verification remains mandatory.

## Specialist Procedure

1. Arrange agreed test data and a free appointment interval. Check current agent
   health, robot disabled, no active training/scan, and any existing queue holds.
2. Install/assign the reviewed candidate separately; this document does not mean
   it has been deployed. Preserve clinic configuration and existing evidence.
3. Prepare a private local UTF-8 request JSON using the schema below. Do not put
   real patient data in Git, chat logs, deployment notes or a public directory.
4. Open the matching date/doctor/interval manually in IDENT, then its expanded
   new-patient form. Turn off appointment notifications manually. Do not save.
5. Run a preview using `Start-IdentFillCheck.ps1 -ConfigPath <installed robot
   config.local.json> -TaskFile <private test JSON>`. Activate the form within
   eight seconds and stop interacting until the result appears.
6. Only after preview and visual review, repeat with `-Execute`, confirm the
   displayed data, activate IDENT within eight seconds, and leave input alone.
7. Inspect all six fields, doctor/date/interval and notifications. Success is
   `filled_not_saved`, **not an appointment**. Do not enable the queue.
8. After a partial result or timeout, never repeat automatically. Inspect IDENT,
   determine whether anything was persisted, and resolve the draft manually.
   The specialist may clear `robot/fill-check-pending.json` only after explicit
   review of its run and the actual form. There is no automatic clear button.

The launcher prints the local `robot/fill-checks/<runId>/result.json` path.
Provider timeout before a result is produced prints `FILL_TIMEOUT`; the pending
receipt, when present, still blocks queue execution through the worker and
direct RunOnce/Loop paths. Configuration and verified calibration are unchanged.

Request shape (placeholders, not runnable clinic data):

```json
{
  "schemaVersion": 1,
  "purpose": "ident-patient-fill-test",
  "doctorCaption": "EXACT CAPTION FROM THE APPOINTMENT TITLE",
  "planStart": "YYYY-MM-DDTHH:mm:00+05:00",
  "planEnd": "YYYY-MM-DDTHH:mm:00+05:00",
  "patient": {
    "surname": "AGREED TEST SURNAME",
    "name": "AGREED TEST NAME",
    "patronymic": "",
    "phone": "AGREED TEST PHONE",
    "birthDate": "YYYY-MM-DD"
  },
  "comment": ""
}
```

Use the actual clinic timezone, not the placeholder offset by assumption.
Intervals must be future, on one calendar date, a multiple of 15 minutes and
no longer than six hours. This stage supports Russian +7/8 phone normalization.
Masked-field compatibility must still be verified on the clinic's IDENT.

## Verification

New serial Windows PowerShell 5.1 tests: FillCheck (pure plan/engine), FillRuntime
(mock UIA, including stale controls and wrong notification state), FillLauncher
(isolated child timeout and retained review receipt). They use synthetic data,
do not operate IDENT and do not establish successful live patient entry.

All 12 targeted checks passed: the three above plus PatientForm,
CalibrationFlow, RobotSafety, SetupPreservation, AgentUpdate, Training,
InstallerPackage (explicit 2.14.9 archive), Observation and CapturePrivacy.
Changed PowerShell syntax and UTF-8 BOM checks passed. The full repository
test suite was not run.

Local release ZIP SHA256:
`F78AF39E4B6DBCF79D972EC1AC4EBD7C5D9B227F4D78ACDFFA6A0488162221AC`.
Local desktop installer ZIP SHA256:
`5E9BFB7E585CB272F49A3BA34B02C9DBADF28B9A65DD555CBDC9FD5BB8F4DE2A`.
These artifacts are not deployed and do not establish booking readiness.

Next gates are supervised live fill, patient identity/creation handling,
calendar selection and a separately authorized booking with independent saved
appointment verification and schedule/reservation reconciliation.
