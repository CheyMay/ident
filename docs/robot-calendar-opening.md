# Supervised Calendar Opening (2.14.13)

## 2.14.15: Label Identity Across Menu Scans

Clinic run `273bd3a79d24488ebf217e3375fb8497` on 2.14.14 stopped at menu_recheck:
CALENDAR_CHANGED, context_changed, changed parts Labels and Selection,
MenuInvokeAttempted=false. The grid proof was unchanged. The report does not
distinguish a real movement from changed tree indices, so neither is established
as the cause. No repeat is automatic; retain/review this exact pending receipt.

The previous context hashes included ordinal UIA tree paths for every label and
for the selected chair/doctor/time anchors. Those paths locate a node within one
scan, not across a provider rebuild. 2.14.15 compares an ordinally sorted multiset
of complete label records excluding only path, preserving text, IDs, class/type,
exact bounds, enabled/offscreen flags and duplicate counts. Selection comparison
retains exact X/StartY/LastY, slot count, drag requirement, chair caption, requested
date/doctor/duration; path changes are recorded separately as ReindexedParts.
Grid identity, strict full-tree preflight, live SQL, operator guard and fresh
MenuItem resolution remain required. There is no geometry tolerance or visibility
bypass. Label swapping at fixed positions, additions/removals, real scrolling,
changed doctors/dates and any coordinate shift remain rejected.

When a rejection changes the target, the local result records changed field names
and coordinate deltas, not patient text. This avoids conflating path changes with
movement on another attempt. Tests include path-only reindexing of all nodes,
target-only reindexing, label count/association mutations, a real 10px movement,
and production callback ordering with mock input. Live opening is still unverified.

Windows PowerShell 5.1 checks passed serially: calendar 56, availability 44,
opening sequence 45, mocked UIA 69, transition 65, launcher, installer and
update/rollback. No tests installed hooks or sent native desktop input.
2.14.15 release SHA-256: `9201F4F8F563E875EAF83CF6E67CD009938F7D014B751310345A2D82021B8E7C`.
Installer SHA-256: `5DF6844CCDFD7A6AFF234AAA4AB6353B5DF27E4DB3D4EFDBC5F0B7B1DCAEA287`.

## Clinic Result And 2.14.14 Follow-Up

The operator supplied a successful `available_read_only` report for the agreed
30-minute test interval. SQL resolved doctor 1904, branch 1, chair 2. The following
opening run `e852258aaa6f4fdd8685ea51f1fab87b` stopped with `partial`,
`CALENDAR_CHANGED`, ActionsAttempted=2, ActionsReturned=1, FormOpened=false and
SaveInvoked=false. In 2.14.13 this error after the right-click is raised by the
calendar recheck before the MenuItem Invoke call. The exact changed tree field
was not recorded, so an incidental popup-related change is a hypothesis, not a
confirmed diagnosis. The pending receipt must not be silently removed or retried.

2.14.14 retains the complete-tree comparison before input. After the popup opens,
it compares the same grid runtime identity and a separate context proof covering
grid geometry/type/visibility, **every direct TextBlock** (including unrelated and
offscreen labels, paths, names, geometry and state), and the exact selection.
Grid display-name and non-text descendants such as scrollbar internals are not
part of this popup transition proof. Scrolling that changes labels/geometry,
changed date/doctor/time/chair, ambiguous/invalid plans and different grids still
stop before Invoke. Fresh SQL proof, input guard, exact menu identity and empty
form readback are unchanged. A popup that makes a required label unavailable is
still rejected; there is no visibility bypass.

Reports now include FailurePhase, CalendarRecheck (allowlisted reason and changed
part names only), and MenuInvokeAttempted, set immediately before Invoke. The
journal advances to `menu_invoke_armed` before that call; an ambiguous/failed run
keeps its receipt. No raw UI text is added to diagnostic reports.

Windows PowerShell 5.1 tests passed serially: calendar 56, availability 44,
opening sequence 45, mocked UIA 69, transition 48 (including production callback
ordering with mock actions and real temporary receipts), launcher, installer and
update/rollback. No test used native input. The real-clinic opening remains
unverified; queue activation and patient writing are still disabled.

2.14.14 release SHA-256: `98BE3FF4DCB2BFE7057472420CD580ED5BE8F540E0EE6FE894F367638C063707`.
Installer SHA-256: `565DDEA3BA874DB3F154FEB678E8ED3457CBDCF448C5FF8F0B06412DDF67AB74`.

Assigned only to the clinic agent on 2026-09-10 at 23:34:02 UTC. Heartbeat
23:34:25 UTC confirmed 2.14.14, online, robot disabled. Requested diagnostics
received at 23:34:45 UTC confirmed succeeded, worker Running, desktop task Ready
and unchanged supervisor hash. Private rollback metadata preserves 2.14.13.
No opening was triggered by deployment and the pending receipt was not changed.

This release adds real read-only SQL availability and an **explicitly confirmed
one-slot opening test**. It is not an unattended booking release. There is no
patient input, Save, dragging, splitting, scrolling, or queue activation.

## Flow

`Start-IdentCalendarCheck.ps1` remains read-only by default. `-CheckAvailability`
adds two fresh SQL reads around the calendar comparison. `-OpenForm` is a separate
child mode, `CalendarOpenCheck`, and additionally requires `-CheckAvailability`,
positive `-DoctorId` and `-BranchId`, and a Yes/No dialog defaulting to No.

The SQL adapter reuses the agent's connection configuration and DPAPI secret
handling through a side-effect-free `-LibraryOnly` import. The fixed parameterized
SELECT reads one day from the captured `dbo.CurrentTimeTable`, `Times`, `Armchairs`
and `StaffsView` schema. It does not read patient rows or join receptions. No SQL
write is implemented. Connection/query timeout is five seconds, rows are capped
at 5000, and `MAXDOP 1` limits query parallelism.

Free coverage requires the exact doctor/chair/branch, working slots throughout
the requested interval, no reception or reserve, no missing coverage, no overlaps
or ambiguous names, no archived identities, and exact stored interval boundaries.
Null/unknown occupancy is not converted to free. SQL row versions and relevant
identity/slot fields must match between reads. A proof older than 15 seconds is
rejected. This is a read-time observation, not a database reservation or lock.

After confirming the one-slot test, the operator has eight seconds to activate
the visible calendar and must leave mouse and keyboard untouched. The child:

1. Checks two stable calendar scans and fresh availability.
2. Journals intent before injecting exactly one right-click at the current
   doctor's current slot coordinates. No left-click or drag is available.
3. Finds the exact visible new-appointment MenuItem, never a Text child,
   continue-from-buffer, split, reserve, or nonworking command.
4. Rechecks SQL availability, grid identity/geometry and the live menu item before
   invoking it once.
5. Reads the independent compact new-appointment form, verifies doctor/date/time
   and six empty input fields (including empty IDENT phone/date masks).

`opened_verified` means only that the empty form opened with matching context.
All patient write/save readiness flags remain false. A previously selected longer
range can cause a form-time mismatch; the test stops without filling it.

## Input And Recovery

The temporary mouse/keyboard guard records event counts only, not typed keys or
text, and never blocks user input. It runs callbacks on a dedicated message-loop
thread. Own tagged injected mouse events are distinguished from other input; the
last-input timestamp is also checked. The right-click uses one SendInput batch,
physical virtual-desktop coordinates, foreground/window-at-point checks, and
rejects held keys. Unsupported DPI context, unavailable hooks, incomplete input
or user activity stop the test. There is no retry or integrity-level bypass.

Implementation references: [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput),
[MOUSEINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-mouseinput),
[low-level mouse hooks](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelmouseproc),
[thread DPI context](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext).

The launcher uses the existing hidden child/job/armed handshake, timeout and
exclusive interaction lease. Before the first click it creates
`calendar-open-pending.json`. Failure or child termination leaves that receipt
for manual review; it blocks another opening and unattended queue/patient writes.
Only verified completion removes this run's receipt. Old `fill-check-pending.json`
is never removed or rewritten, and still blocks repeat patient input. Update and
rollback preserve both receipts byte-for-byte.

## Operator Commands

Start with a read-only check on the exact visible date/doctor/time, supplying the
clinic's offset. This example uses synthetic identifiers and a synthetic date:

```powershell
$p = "$env:LOCALAPPDATA\Code9\IdentAgent\robot"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$p\Start-IdentCalendarCheck.ps1" -ConfigPath "$p\config.local.json" -DoctorCaption 'Sample O. M.' -Start '2099-09-20T09:00:00+05:00' -DurationMinutes 30 -CheckAvailability
```

Only after `available_read_only`, use the returned and operator-checked IDs for
the same target, adding `-OpenForm -DoctorId <actual-id> -BranchId <actual-id>`.
Opening rechecks everything rather than trusting the previous report. An update
does not itself run either check. No screenshots or new patient data are needed.

## Verification Boundary

Local tests passed: 56 calendar assertions, 44 availability assertions (including
typed ADO.NET DataTable fixtures), 41 opening-sequence assertions and interop
compilation, 69 mocked UIA readback/menu assertions, bounded launcher, existing
patient/fill/observation/runtime/safety tests, agent self-test, worker lifecycle,
installer contents and update/rollback. Tests run serially under Windows
PowerShell 5.1. No local test installed input hooks or sent desktop input.

Real-clinic opening has not yet been verified. Full patient handling, the prior
fill failure, multi-slot input and verified appointment saving remain unfinished.

Release SHA-256: `A059D280EA1DE73B01FD96954E62ABB7AD26DFA38E819FE012E7ADFEBC200806`.
Installer SHA-256: `663131B357EAB3DF8598E9746F4EC8F89D6CA72AAC24F6E91C7F0877791E002E`.

## Deployment Observation

Published and assigned only to `stomazub-laptop-7osrm534` on 2026-09-10 at
19:40:18 UTC, from the previously assigned/installed 2.14.11. Private rollback
metadata was saved before assignment. Server release hash matches the archive.
Heartbeat at 19:40:51 UTC reported 2.14.13, online, robot disabled and no active
training/calibration. Requested diagnostics received at 19:41:10 UTC reported
`update.status=succeeded`, worker task `Running`, desktop task `Ready`, and the
unchanged verified supervisor hash. This is an observation, not continuous
monitoring or proof of sleep/wake recovery. No opening or booking was run by
deployment. The next clinic step is the read-only `-CheckAvailability` command.
