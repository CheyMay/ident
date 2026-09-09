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

The surname alias is a local code change, not a new deployed agent release.
CalibrationFlow, RobotSafety and Training tests pass. Active clinic profiles,
queue state and booking switches were not modified. Autonomous booking remains
unapproved pending patient selection/creation, calendar control and an independently
verified supervised booking.
