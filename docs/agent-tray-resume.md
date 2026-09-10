# Agent Tray And Resume Recovery

Local release candidate 2.14.10. Not assigned to the clinic during this change.
The update does not enable the robot, clear pending booking evidence or change
Windows sleep settings. Live sleep/wake on the clinic PC remains to be checked.

## Changes

- Normal panel shortcuts and setup launches request hidden PowerShell windows.
  The status CMD starts the panel asynchronously and hidden. Interactive initial
  setup still uses its console for configuration; arbitrary operator terminals
  are not hidden or terminated.
- Find SQL and Check Database enqueue commands to the worker instead of opening
  a persistent `-NoExit` console. The worker serializes these with other work;
  the panel remains responsive and displays running/error states. A local SQL
  discovery does not overwrite the server's control revision.
- The panel is single-instance per Windows session. Opening the shortcut again
  signals the existing panel; it does not create another tray icon.
- X, Alt+F4 and minimizing hide the panel from the taskbar, retaining its tray
  icon. Double-click or the tray Open command restores it. The explicit panel
  exit asks for confirmation and does not stop the worker. Windows shutdown
  is not cancelled. A force-killed panel is not made unkillable.
- The supervisor watchdog measures active system time, not elapsed wall time.
  It still restarts a stale/crashed worker, but sleep/hibernation is not counted
  toward the 150-second stale threshold. Resume adds 45 active seconds of grace.
  Fresh timestamp tokens support backward wall-clock corrections; repeatedly
  reading the same cached timestamp does not renew worker liveness.
- The worker detects the gap between uptime and active time. On resume it makes
  heartbeat and schedule refresh due again. New robot polling waits at least
  60 active seconds after resume or worker startup, then retains the existing
  desktop-unlocked, user-idle, calibration and pending-receipt guards.
- A one-minute recurring Task Scheduler trigger supplements logon and failure
  restart. `IgnoreNew` prevents a parallel task instance; existing supervisor
  and worker mutexes remain. The status-panel task does not recur every minute,
  so an explicit panel exit is respected. Battery settings and no execution
  time limit remain; the task does not wake a sleeping machine.
- Updating re-registers existing tasks too, and migrates only known shortcuts
  whose arguments point to this exact installation. An optional shortcut error
  does not prevent background task installation.

Existing schedule data, configuration, patient-form calibration, reservations,
success markers and ambiguous-execution receipts are preserved. An interrupted
booking is not blindly resubmitted after waking or restarting.

## Windows Basis

[QueryUnbiasedInterruptTime](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryunbiasedinterrupttime)
excludes sleep and hibernation and does not follow wall-clock corrections.
[GetTickCount64](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64)
provides uptime; comparing their deltas detects sleep gaps with a two-second
tolerance. Sampling resolution can make their absolute values differ slightly;
the implementation compares elapsed deltas, not absolute equality.

[FormClosing](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.form.formclosing)
supports cancelling an ordinary user close while leaving shutdown distinct.
[Task repetition without a duration](https://learn.microsoft.com/en-us/windows/win32/taskschd/repetitionpattern-duration)
is indefinite. The recovery trigger does not change Windows power policy.

## Clinic Verification

1. Keep the robot disabled and finish any active training/capture before update.
2. Apply the reviewed update through the administrator workflow, not initial
   setup. Verify the installed version, a fresh worker/backend heartbeat, and
   the supervisor's reported `codeSha256` against the installed supervisor file.
   A version number alone does not prove the old process has reloaded, especially
   on a legacy startup-folder installation.
3. Exit the old panel using its tray menu, then open the updated shortcut.
   Test X, minimize, tray restore and opening the shortcut twice. Only one
   panel/icon should remain, without a persistent PowerShell window.
4. With no booking in progress, sleep and wake the PC. The agent is expected to
   be offline during sleep. Verify a fresh heartbeat and schedule after network
   connectivity returns. Do not promise a fixed reconnect time without network.
5. Inspect logs/status if recovery fails. Do not delete pending receipts or
   enable the queue merely because the panel reopened.

Task recovery requires the Windows user to remain signed in and the task to be
enabled. Startup-folder fallback still benefits from the running supervisor,
but does not have the extra recurring Task Scheduler recovery trigger.

## Verification

Passed sequential Windows PowerShell 5.1 checks: PowerRecovery,
AutostartRecovery, Tray, Supervisor, SupervisorLifetime, WorkerLifecycle,
Reliability, Training, AgentUpdate, SetupPreservation, FillCheck and
InstallerPackage for 2.14.10. WorkerLifecycle waits through a real startup
minute against an isolated fake backend; it completed one synthetic execution
and recovered completion acknowledgement without repeating that execution.

Tray handlers were exercised against a fake form, task registration was mocked,
and the actual native repetition-trigger object and a temporary shortcut were
checked without changing installed tasks. The panel preview was rendered and
visually inspected. Changed PowerShell syntax and encodings passed. Full tests
and actual sleep/hibernate on clinic hardware were not performed.

Local release ZIP SHA256:
`AD20BE3A6B4D9A7711E98FFA5550C061E17EC3BDE100C9D873C08B70C0C8EAF4`.
Local installer ZIP SHA256:
`DE418F15C0D0F5D5D464502BE3A05C2D77AAF2FA7CFB0AAE994E796080215552`.
These hashes identify local artifacts, not an installed clinic release.
