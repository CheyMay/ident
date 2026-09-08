import assert from 'node:assert/strict';
import test from 'node:test';
import {
  assertBookableWindow,
  createReservation,
  overlayReservations,
  reconcileReservations,
  SlotUnavailableError,
  TimetableStaleError
} from '../src/ident/slot-reservations.js';

function timetable(intervals = null) {
  return {
    receivedAt: '2026-08-27T10:00:00.000Z',
    Doctors: [{ Id: 10, Name: 'Doctor' }],
    Branches: [{ Id: 20, Name: 'Clinic' }],
    Intervals: intervals || [0, 15, 30, 45].map((minute) => ({
      DoctorId: 10,
      BranchId: 20,
      StartDateTime: `2026-09-01T10:${String(minute).padStart(2, '0')}:00+03:00`,
      LengthInMinutes: 15,
      IsBusy: false
    }))
  };
}

function ticket(id = 'ticket-1', start = '2026-09-01T10:00:00+03:00', end = '2026-09-01T10:45:00+03:00') {
  return {
    Id: id,
    DoctorId: 10,
    PlanStart: start,
    PlanEnd: end
  };
}

test('reserves every 15-minute segment of a 45-minute booking', () => {
  const source = timetable();
  const booking = ticket();
  const window = assertBookableWindow({ timetable: source, ticket: booking, branchId: 20 });
  assert.equal(window.durationMinutes, 45);

  const record = {
    id: booking.Id,
    status: 'queued',
    reservation: createReservation(booking, 20, { now: new Date('2026-08-27T10:00:00Z') })
  };
  const overlaid = overlayReservations(source, [record], new Date('2026-08-27T10:01:00Z'));
  assert.equal(overlaid.Intervals.filter((item) => item.IsReserved).length, 3);
  assert.equal(overlaid.Summary.reservedIntervals, 3);
});

test('rejects overlapping reservation and non-aligned start time', () => {
  const first = ticket('first');
  const records = [{
    id: first.Id,
    status: 'queued',
    reservation: createReservation(first, 20, { now: new Date('2099-08-27T10:00:00Z') })
  }];
  assert.throws(
    () => assertBookableWindow({
      timetable: timetable(),
      ticket: ticket('second', '2026-09-01T10:30:00+03:00', '2026-09-01T11:00:00+03:00'),
      branchId: 20,
      records
    }),
    SlotUnavailableError
  );
  assert.throws(
    () => assertBookableWindow({
      timetable: timetable(),
      ticket: ticket('unaligned', '2026-09-01T10:05:00+03:00', '2026-09-01T10:20:00+03:00'),
      branchId: 20
    }),
    /кратным 15 минутам/
  );
});

test('reconciles reservation after refreshed IDENT timetable confirms busy segments', () => {
  const booking = ticket();
  const record = {
    id: booking.Id,
    status: 'robot_completed',
    reservation: createReservation(booking, 20, { now: new Date('2026-08-27T10:00:00Z') })
  };
  record.reservation.status = 'awaiting_timetable';
  const busy = timetable().Intervals.map((item, index) => ({ ...item, IsBusy: index < 3 }));
  assert.equal(reconcileReservations([record], timetable(busy), new Date('2026-08-27T10:02:00Z')), true);
  assert.equal(record.reservation.status, 'confirmed');
  assert.equal(record.reservation.releaseReason, 'confirmed_by_timetable');
});

test('rejects a booking when the IDENT timetable is stale', () => {
  assert.throws(
    () => assertBookableWindow({
      timetable: timetable(),
      ticket: ticket(),
      branchId: 20,
      maxTimetableAgeMinutes: 30,
      now: new Date('2026-08-27T11:00:01Z')
    }),
    TimetableStaleError
  );
});

test('uncertain saves and pending timetable refreshes do not reopen slots on a timer', () => {
  for (const status of ['awaiting_review', 'awaiting_timetable']) {
    const record = {
      id: 'held', status: status === 'awaiting_review' ? 'robot_failed' : 'robot_completed',
      reservation: createReservation(ticket(), 20, { now: new Date('2026-08-27T08:00:00Z'), holdMinutes: 1 })
    };
    record.reservation.status = status;
    const later = new Date('2026-08-27T12:00:00Z');
    reconcileReservations([record], timetable(), later);
    assert.equal(record.reservation.status, status);
    assert.equal(overlayReservations(timetable(), [record], later).Summary.reservedIntervals, 3);
  }
});
