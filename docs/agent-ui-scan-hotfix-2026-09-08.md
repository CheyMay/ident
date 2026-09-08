# Agent UI Scan Hotfix 2.12.1

## Incident

The clinic's Calibrate command failed in Get-UiTreeRows at `return @($rows)`
with ArgumentException (argument types do not match). The collection was a
generic List[object]. Consequently no fresh timestamped UI capture was saved;
the user repeatedly sent the same older, minimized-window capture.

## Fix and Verification

- Materialize generic scan/root collections with ToArray().
- Preserve a JSON array for empty, single-root and multiple-root Inspect exports.
- Test-IdentUiScan.ps1 scans a hidden test-only WinForms window, without using
  clinic data or interacting with the user's application windows.
- Windows PowerShell 5.1 checks passed: Test-IdentUiScan.ps1,
  Test-IdentRobotSafety.ps1 and Test-IdentReliability.ps1.

## Clinic Deployment

- Earlier this session, read-only discovery verified PZ through
  tcp:127.0.0.1,15000. The former tcp:192.168.0.3,15000 address timed out.
  Only desired SQL endpoint/database were changed; credentials were retained.
- Schedule export recovered. A remote restart was verified by a new worker PID,
  heartbeat and subsequent successful timetable export.
- Release 2.12.1 was published and assigned to stomazub-laptop-7osrm534.
  Live status at 2026-09-08T14:27:31.861Z reported 2.12.1 online.
- Release SHA256: 58cab261f8b4511530109a6b7bf4ee2b7cd954b5bba75f8c28df9baf64a78069.
- Robot remains disabled and unconfigured. No tickets were claimed or executed.
  Existing robot profile and queue were not changed.

## Still Required

A fresh capture of the open New Appointment dialog, followed by field mapping
and a supervised non-saving rehearsal. Separate surname, given name and
patronymic fields must not be treated as a single full-name input. Opening the
correct calendar slot and positively verifying a saved appointment remain
unverified. The reason the IDENT appointment dialog closes after a few minutes
has not been established. This hotfix is not approval for unattended bookings.

## Next Supervised Session

The last attachment before AnyDesk disconnected had the same SHA256 as the
earlier 22-row minimized-window scan. A newer capture may exist on the clinic
PC, but none has been received or validated. At 2026-09-08T14:30:07.417Z the
agent remained online, schedule state was ok (last success 17:28:03 +03:00),
and both old tickets remained queued with no robot claims.

1. Keep the robot disabled. Inspect timestamps and metadata of existing
   ui-tree-*.json and calibration-report.json before asking for another scan.
2. If necessary, reopen New Appointment and collect one fresh bounded scan.
   Accept only a timestamped capture with rootName/patterns and visible fields
   matching the current form. Confirm the exact output filename and console
   result; do not rely on an unchanged clipboard or the older ui-tree.json.
3. Map separate name fields, phone, birth date, comment and appointment settings.
   Check patient search/selection and notification state without saving.
4. Agree on one test identity and slot. Verify the full doctor/date/time range
   and rehearse without saving before a supervised single appointment test.
5. Verify the saved appointment in IDENT and refreshed schedule before enabling
   unattended operation. Review the two old queued tickets with the user first;
   do not automatically execute or discard them.

The user cannot reconnect until the next morning. Do not schedule bookings,
enable the robot, or change clinic configuration while waiting for that session.
