# IDENT Training Archive Audit: 2026-09-09

## Scope

Input: the four-capture `IDENT-training.zip` supplied by the operator.
SHA256: `888689eee75e102f6cbcfc80e6fb6eec6dea592f7c8dcc0742b8d6f63dddb87c`.
Raw UI text and patient data remain outside the repository. This report contains
only control identifiers, structural findings and readiness constraints.

The archive was read locally without executing or extracting its contents.
Verified the exact nine-file allowlist, capture IDs, hashes against both session
and capture summaries, uncompressed byte counts and UI row counts. The manifest
reports zero actions and no profile activation. Observe-mode summaries set
calibration fields to false by design; those flags are not calibration results.

## Captures

| Capture | UI rows | Observed state |
| --- | ---: | --- |
| 01 | 928 | Calendar and other descendants of the main IDENT window |
| 02 | 37 | Empty new-appointment form; save disabled |
| 03 | 51 | Patient search results; save still disabled |
| 04 | 44 | Selected patient; save enabled |

Captures 03 and 04 have matching appointment titles. Capture 02 has a different
date and time: do not treat all three as one uninterrupted appointment.

## Form Evidence

- `_surnameTextBox` is an enabled Edit with ValuePattern in captures 02 and 03.
  The previous name heuristic did not recognize this exact ID. Added a narrow
  alias and tests for ambiguity, a different suffixed ID, full-name confusion
  and a disabled field. The alias resolves against the actual supplied tree.
- Name, patronymic and phone inputs have neither Name nor AutomationId in the
  supplied tree. Their position matches the supplied form screenshot, but a
  stable runtime adapter has not been verified. Do not bind them by an absolute
  desktop coordinate or a cached tree index alone.
- The masked input has ID `MaskedTextBox`; the comment inner input has ID
  `_textBox`. These generic IDs need form-specific validation before use.
- `_receptionTimeTextBlock` exposes the appointment interval as text, not as an
  editable time input. The title exposes doctor, date and interval for checking.
- Search results appear as text cells, not selectable UIA rows. More than one
  result is present. A first-match click is not an identity check. Validate the
  requested patient and stop on ambiguity; the selection adapter is pending.
- Capture 04 enables the save command but is still the pre-save form. This is
  not proof that an appointment was saved.

## Calendar Evidence

`cttGrid` / `TimeTableGridControl` has 56 descendants. The tree exposes chair
headers, doctor headers, time labels and the scrollbar. It does not expose a
Grid/Selection/Drag pattern for appointment intervals, nor readable free/busy
cells in this capture. Scope calendar analysis to this control; unrelated
panels also occur under the main window.

Doctor headers repeat within the day. The interval between the 13:30 and 14:00
labels has an extra header-height gap compared with adjacent half-hours. A
single pixels-per-minute formula for the whole day is invalid. Some rows extend
outside the calendar viewport; IsOffscreen alone is not a sufficient click guard.

The operator demonstrated the manual workflow: left-button drag within the
doctor column, right-click the selection, then the first new-appointment menu
item. Do not use the separate continue-from-clipboard item. The automated drag,
menu transition and full interval verification are not implemented/verified by
these captures.

## Next Evidence And Release Boundary

Capture the selected interval, its context menu, and the new-appointment title
after opening that selection. Prefer a 45-minute example. Do not save it.
Clarify the new-patient creation command before clicking it: this archive does
not establish whether it commits immediately or opens another form.

At the first audit the surname alias was only a local code change. It was later
included in deployed release 2.14.5.
CalibrationFlow, RobotSafety and Training tests pass. Active clinic profiles,
queue state and booking switches were not modified. Autonomous booking remains
unapproved pending patient selection/creation, calendar control and an independently
verified supervised booking.

## Second Supplied Archive: Menu Attempt

The replacement archive received at 19:59 +03:00 contains two captures, five
allowlisted files. ZIP SHA256:
`8234ae25cf8113b818577555a80fd0d2c5901a14e4637cc90264faffc64007c7`.
Session: `22eafc963af5424693f97c8b80f4c5b3`. Export time:
`2026-09-09T19:59:17.5205078+03:00`. IDs, hashes, byte sizes and row counts match.

Capture 01 has 1090 rows, capture 02 has 988. Both start at the main WinForms
window and contain no Menu or MenuItem controls. No new-appointment or
split-interval command was found. The successful capture count is therefore
not proof of capturing the open popup. These files cannot bind that menu or
prove a particular interval selection.

The operator reports that choosing the split-interval command changed the
interval immediately, without a configuration dialog. Do not replay that command
for observation or presume it is a harmless navigation step. No agent action
was executed; the manifest reports actionsExecuted=0 and profileActivated=false.

Release 2.14.6 adds a separate menu-only mode. It reads the item under the
operator's pointer, walks at most 24 same-process ancestors to a Menu and its
native container, and checks identities and visibility before and after capture.
Only that menu subtree is exported. Missing/closed/replaced menus, a foreign
process or zero visible MenuItems cause failure instead of a successful calendar
capture. It never moves the pointer or invokes a menu command.

Primary API references: [AutomationElement.FromPoint](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement.frompoint),
[TreeWalker.GetParent](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.treewalker.getparent).
Unit tests do not establish live IDENT menu accessibility; a controlled menu-only
capture on the clinic computer is still required. Autonomous booking remains unverified.

## Third Supplied Archive: Menu Confirmed

Received the menu-only archive produced by clinic release 2.14.6. ZIP size:
1864 bytes. SHA256:
`28478d02ea69cbf6e59821b7d4bb7787b2fea86f0c7b176bab82c5d5e6c90965`.
Session `5f9d6a17e40f43dca2695d908cfd4532`; capture time
`2026-09-09T20:14:20.4077136+03:00`, export time
`2026-09-09T20:14:53.9115344+03:00`. Verified the three-file allowlist,
IDs, SHA256 values, byte counts and row count. No files were executed or extracted.

The captured root is ControlType.Menu / ContextMenu. The 18 rows contain six
MenuItems, three Separators and eight Text nodes. Summary observedSurface=menu
and menuItemsScanned=6 agree with the actual tree. This is now positive evidence
of live popup accessibility, not another calendar-only capture.

- New appointment: enabled, visible MenuItem with InvokePattern.
- Split interval: enabled, visible MenuItem with InvokePattern; operator confirmed
  it immediately changes the interval. Do not invoke it just to collect evidence.
- Add reserve and make nonworking: enabled MenuItems with InvokePattern; neither
  is a safe substitute for opening a new appointment.
- Change doctor: ExpandCollapsePattern, not InvokePattern.
- Command text also appears in TextBlock descendants. Match MenuItem, not the
  duplicate label. These entries have no AutomationId.

Ran the existing Get-CalibrationSelector(newAppointmentButton) locally against
this exact tree. It resolved the actual first new-appointment MenuItem, not a
TextBlock or adjacent command. No profile was uploaded or activated. No menu
command was invoked. The manifest records actionsExecuted=0 and profileActivated=false.

Remaining transition evidence: the new-appointment form opened from the intended
selected interval, with matching doctor/date/start/end in its title. Do not
repeat splitting or save a patient for this check. Existing patient-form captures
remain available; a menu binding alone does not implement calendar selection,
patient identity validation, or verified unattended booking.
