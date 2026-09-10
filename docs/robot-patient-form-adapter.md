# Patient Form Adapter: First Stage

Historical first-stage report. The next local candidate adds a separately
confirmed fill-only runtime; see [supervised fill](robot-supervised-fill.md).
Neither stage is proof of a completed or unattended clinic booking.

## Status

Local candidate implementation for release 2.14.8. Not published or assigned
to the clinic. The clinic remains on 2.14.7 with the robot disabled.
This stage locates six candidate fields and validates displayed appointment
context. It does not implement patient selection, entering values, calendar
dragging/splitting, saving, or verifying a saved booking.

## Implemented

`robot/ident-rpa/IdentPatientForm.ps1` is a bounded, pure analyzer of an existing
UIA tree. It has no Windows input, network, database, file-writing or queue API.
It accepts one visible WPF new-appointment window with at most 256 rows and
checks unique paths, root membership, positive bounds, containment, enabled
state and ValuePattern availability. Missing or ambiguous structure returns
an empty field map and a fixed error code.

The surname and birth-date IDs anchor the patient section. The observed aligned
card/name inputs and phone-prefix control constrain anonymous first-name,
patronymic and phone candidates. The appointment time anchors its ScrollViewer;
only the nested comment Edit in that panel is eligible. City/street/referral/
insurance `_textBox` instances and the two patient-note fields are not used.
Paths are derived from each supplied tree, not stored as fixed selector indices.
Window movement and proportional scaling are supported within tested bounds.

These spatial relationships are inferred from the supplied screenshots and
trees. They are candidate evidence, not proof of semantic identity in an unseen
IDENT layout. In particular, an anonymous-field rearrangement that preserves
the same layout cannot be detected from these properties alone. A live runtime
adapter and supervised field/value verification are still required before input.
`ReadyForInput` and `ReadyForUnattendedExecution` always remain false.

`Assert-IdentPatientFormContext` compares an explicitly mapped doctor caption,
date, start and end against clinic wall-clock values. It does not guess an
abbreviated doctor name from a full name or treat a matching instant in another
timezone as the same displayed time. It rejects inconsistent offsets, fractional
minutes, non-15-minute boundaries and durations over six hours. This assertion
does not authorize input and is not yet a booking workflow step.

Automatic calibration now includes `patientFormBindings` and writes a separate
local `patient-form-candidate.json`. Active configuration is unchanged; the
generic selectors are not replaced with anonymous cached paths. The split-name
flag prevents interpreting the surname as a full-name input. Candidate profiles
stay disabled and incomplete. Observations and server metadata are unchanged.

## Verification

- Both privately stored clinic archives resolve all six intended candidates:
  compact 45-minute form and expanded 30-minute form. The comment moves from
  `0/15/5/0` to `0/36/5/0`; the analyzer follows the current panel.
- Synthetic fixtures contain no patient data. They cover compact/expanded forms,
  five scales, negative desktop origins, reordered input arrays and changed paths.
- Missing, hidden, disabled, off-viewport, non-writable, duplicated and mixed-root
  controls fail; interval text/title mismatch fails. Invalid tree sizes and
  malformed bounds cannot produce an executable result.
- Calibration integration preserves the active profile and reports candidate
  readiness as false even when all six fields are found.
- Serial tests passed: PatientForm, CalibrationFlow, Observation, MenuCapture,
  Training, CapturePrivacy, RobotSafety, AgentUpdate, SetupPreservation and
  InstallerPackage for the explicit 2.14.8 archive. PowerShell syntax/BOM checked.

Local release ZIP SHA256:
`E08DD145E6A0823B01C5BC17C1E3D94A307998C761B91F839494369F7F5C422C`.
Local desktop installer ZIP SHA256:
`D675D9AE2C1C0AD9BBA338C90746069E5223403BDC85B5B61C7B2E5FE19C68ED`.
These hashes describe local artifacts, not a deployed or booking-ready release.

## Next Implementation

1. Resolve candidate fields against a fresh live window, verify runtime identity
   and read-back, and support a supervised fill-only operation with no save call.
2. Handle existing-patient lookup/selection and new-patient creation explicitly;
   stop on multiple identity matches and never equate the save button with proof.
3. Implement validated calendar date/doctor/interval selection and immediate
   split semantics, with independent availability/context checks.
4. Perform one authorized supervised booking and verify the resulting appointment
   plus schedule/reservation feedback before enabling any unattended queue.
