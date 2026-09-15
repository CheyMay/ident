# One-Run Booking Trial

## Current Boundary

The operator requested a single supervised run starting from open IDENT, without
manually selecting the date, doctor, interval or preparing the patient form.
The first integrated run must stop before Save. It is not the queue workflow.

`IdentBookingTrial.ps1` currently provides the request contract, a read-only
pending-receipt resolver and the orchestration engine. It is NOT wired into
Start-IdentRobot, a launcher, the desktop or the release package. There is no
live end-to-end command yet. Do not treat mocked callbacks as a working UI adapter
or deploy another package just to expose an incomplete entry point.

## Sequence

1. Confirm the exact request and check installation, exclusive ownership and
   pending reviews. Resolve receipt run IDs from their files, never an old image.
2. Verify navigation and patient adapters support the starting screen BEFORE
   journaling or any UI action. Unknown views or selectors must stop here.
3. Journal the navigation intent, navigate to the requested date and read it back.
4. Use the verified calendar-opening adapter: current doctor/branch SQL proof,
   exact selected slot, one menu invocation, matching empty appointment form.
5. Search and unambiguously select an existing patient or prepare a new form,
   according to the explicit request mode. Confirm the appointment context,
   identity and notifications-off state before passing to the fill adapter.
6. Use the existing no-save fill adapter and independently verify all six final
   values, original field/root identities and appointment context.
7. Return filled_not_saved and retain the overall receipt for operator review.
   Never invoke Save or acknowledge a backend booking.

The engine does not expose a Save callback or accept unverified completion.
StageAttempts counts invoked UI-stage callbacks, NOT physical mouse clicks.
A callback can contain multiple guarded actions. A failed stage is never retried,
and no subsequent callback is run. An error after journaling retains a manual
review requirement. Unknown provider messages and patient values are not reported.

## Required Runtime Work

- Inspect the newly requested full-calendar UI scan, including the left-hand
  date navigation. The older pasted main-window scan is minimized, with negative
  geometry; the calendar-grid fixture alone does not bind the date picker.
- Bind and test real date navigation and patient-search/selection/new-form
  transitions. The retained private archives cover compact and expanded forms,
  but do not currently establish these transition controls.
- Implement one bounded child process and interaction lease across all stages,
  one operator confirmation and one durable receipt covering every UI mutation.
  Reuse existing input guards, SQL proof and no-save form adapters; do not chain
  separate launchers that release the lock or require repeated focus countdowns.
- Keep an overall hold before the first navigation action through final review.
  Other entry points must respect it after a crash; do not enable queue processing.
- Wire the runtime/launcher only when all required callbacks have real adapters,
  with mock runtime and launcher lifecycle tests before a new immutable release.

The operator agreed to capture the main calendar via the installed training UI,
without selecting a particular date or doctor. Await that archive. Do not repeat
the already-passed 2.14.19 calendar opening or expanded-form preview.

## Existing Clinic Evidence

- Calendar run 91499a95a6c046c1979ef35028eac5fb: opened_verified, six fields,
  one transient unavailable-window read, Rogozhin / 2026-09-24 09:00-09:30 +05:00.
- Fill run 58824470bacc4fb7bef578b03f53491b: preview, no automatic input or Save.
- The next suggested fill block stopped reading the old result path before
  receipt retirement or execution. No new fill ran. The actual old pending run ID
  and report availability still need read-only inspection on the clinic PC.

## Local Verification

49 sequential Windows PowerShell 5.1 assertions cover ordered stages, missing
capabilities, consent, operator interruption, wrong date, failed opening, ambiguous
patient, notifications, partial fill, every final value, changed root, unexpected
Save reports, journal failure and receipt lookup. Receipt fixtures cover missing
directories/reports, dynamic run IDs, traversal strings and byte preservation.
These are synthetic orchestration tests, not evidence of successful live input.
