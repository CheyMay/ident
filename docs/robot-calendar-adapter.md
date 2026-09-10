# IDENT Calendar Adapter

## Delivery Boundary

Next stage: [2.14.13 live availability and supervised one-slot opening](robot-calendar-opening.md).
The description below records the read-only 2.14.12 boundary; it is not a claim
that the newer explicit opening mode is read-only.

2.14.12 adds a **read-only calendar planner**, not an autonomous booking robot.
It is a local release candidate, not assigned to the clinic. No existing agent,
queue, calibration, patient record, or pending-review receipt is changed by this work.

Implemented:

- Request validation: explicit time-zone offset, future same-day interval, 15-minute
  boundaries, maximum six hours. Calendar matching uses the request's local wall time.
- One visible `cttGrid` / `TimeTableGridControl`, a full visible date, chair columns,
  doctor headers, paired left/right time labels, and explicit interval boundaries.
- Repeated doctor headers define separate shifts. No interpolation across a shift
  header, unseen quarter-hour boundary, or clipped end-of-interval label.
- Selection planning ends at the last included row, not the following interval.
- Two stable scans, exact window/process/runtime identity, exclusive interaction
  lease, user-input cancellation, and a hidden child with a kill-on-close job and timeout.
- Exact candidate matching for the new-appointment MenuItem; never the similarly
  named Text child or continue-from-buffer command. The candidate is not invoked.

The planner deliberately returns `ReadyForInput=false`,
`ReadyForUnattendedExecution=false`, and `AvailabilityVerified=false`, even on
success. `planned_read_only` means geometry and request context matched in two
scans. It does not mean an appointment was opened, saved, or verified.

## Evidence

The fixture preserves the 56 grid-descendant rectangles recovered from the earlier
training scan in this task. Captions, dates and visibility flags are synthetic:
the old sanitized output omitted those values. There are paired 30-minute labels,
three chair columns, repeated doctor headers between 13:30 and 14:00, and a
partially clipped 16:00 label. `IsOffscreen=false` alone cannot establish visibility.
No patient data or raw training archive is committed.

The captured grid exposes text labels, not readable appointment/free-busy cells.
This is why dragging or splitting is not authorized by a geometric match. A drag
over an existing appointment could move it; guessing occupancy from this scan is
not acceptable.

## Supervised Check

After a separately agreed installation of 2.14.12, with the robot disabled, open
the calendar on the intended date. Run the following command on the clinic PC,
substituting the actual visible doctor caption and agreed future time, including
the clinic's UTC offset. The example doctor and year below are synthetic.

```powershell
$p = "$env:LOCALAPPDATA\Code9\IdentAgent\robot"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$p\Start-IdentCalendarCheck.ps1" -ConfigPath "$p\config.local.json" -DoctorCaption 'Doctor B' -Start '2099-09-20T09:00:00+05:00' -DurationMinutes 30
```

Within eight seconds activate the calendar, then leave mouse and keyboard alone.
The check uses no sound cue and performs no UI input. Reports remain under
`robot/calendar-checks/<runId>/result.json`; they contain status and counts, not
the raw UI tree. No new patient data is needed. Existing `fill-check-pending.json`
is preserved; an actual `execution-pending.json` blocks the check.

Failures are explicit: `CALENDAR_WRONG_DATE`, `CALENDAR_DOCTOR_AMBIGUOUS`,
`CALENDAR_SPLIT_REQUIRED`, `CALENDAR_SCROLL_REQUIRED`, `CALENDAR_SHIFT_BOUNDARY`,
`CALENDAR_CHANGED`, `CALENDAR_USER_ACTIVE`, or a sanitized provider/timeout error.
No failure triggers a retry, scrolling, splitting, or a fallback click.

## Still Required Before Enabling Bookings

1. Confirm the unredacted visible date/doctor text matches the adapter on the actual
   IDENT installation. Existing screenshots cannot establish this programmatic match.
2. Connect fresh availability and exact doctor/chair identity, then a supervised
   calendar-selection/opening adapter with input ownership and form-context checks.
3. Complete existing/new-patient handling and resolve the previous guarded
   `FILL_FORM_CHANGED` outcome without deleting the pending receipt blindly.
4. Test one explicitly agreed appointment end to end, including save-result
   verification and duplicate prevention, before enabling the queue.

## Local Verification

Run serially under Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File test/Test-IdentCalendar.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File test/Test-IdentCalendarLauncher.ps1
```

The launcher test runs isolated synthetic children, including a deliberately
sleeping child to verify timeout cleanup. It never connects to IDENT.

Verified locally on 2026-09-10: 56 calendar assertions; calendar launcher;
patient-form, fill-check, fill-observation, fill-runtime, fill-launcher and robot
safety regressions; installer contents; update/rollback lifecycle. All passed
serially in Windows PowerShell 5.1. No live IDENT calendar check has run yet.

Built candidate archives (not published or assigned):

- `ident-agent-release-2.14.12.zip`, SHA-256
  `3CB71EB37B4348870431B773960C0C26BAA3662E63E5B11E5932E5555909766D`.
- `ident-desktop-2.14.12.zip`, SHA-256
  `6435997FA8E3EF2182753904EDA4E51DD5D9654A387460DD7B6654BD630F6E80`.
