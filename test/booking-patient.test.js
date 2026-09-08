import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeBirthDate } from '../src/date.js';
import { normalizeBookingTicket } from '../src/ident/contracts.js';
import { normalizeAndValidateTicket, normalizeAndValidateIdentTicket } from '../src/ident/ticket-validation.js';

const booking = {
  id: 'patient-boundary', clientFullName: 'Test Patient', clientPhone: '+79990000000',
  planStart: '2099-09-09T09:00:00+05:00', durationMinutes: 360, clientBirthDate: '2000-02-29'
};

test('birth dates remain date-only and reject impossible, future and non-date values', () => {
  const now = new Date('2026-09-08T12:00:00Z');
  for (const date of ['1900-01-01', '2000-02-29', '2026-09-08']) {
    assert.equal(normalizeBirthDate(date, now), date);
  }
  for (const date of ['1900-02-29', '2001-02-29', '2000-04-31', '2000-13-01', '1899-12-31',
    '2026-09-09', '2099-01-01', '29.02.2000', '2000-02-29T00:00:00Z', ' 2000-02-29', {}, 0]) {
    assert.equal(normalizeBirthDate(date, now), null, String(date));
    if (date !== '2026-09-09') {
      assert.throws(() => normalizeBookingTicket({ ...booking, clientBirthDate: date }), /clientBirthDate/);
    }
  }
  for (const date of [undefined, null, '']) {
    assert.equal(normalizeBookingTicket({ ...booking, clientBirthDate: date }).ClientBirthDate, undefined);
  }
});

test('booking normalization and both ticket validators enforce a six-hour maximum', () => {
  for (const durationMinutes of [15, 30, 45, 120, 345, 360]) {
    const ticket = normalizeBookingTicket({ ...booking, durationMinutes });
    assert.equal(ticket.DurationMinutes, durationMinutes);
    assert.equal(normalizeAndValidateTicket(ticket).ok, true);
    assert.equal(normalizeAndValidateIdentTicket(ticket).ok, true);
  }
  for (const durationMinutes of [0, -15, 16, 30.5, 375, 720, '360abc']) {
    assert.throws(() => normalizeBookingTicket({ ...booking, durationMinutes }), /durationMinutes/);
  }
  assert.throws(() => normalizeBookingTicket({ ...booking, durationMinutes: 15,
    planEnd: '2099-09-09T15:15:00+05:00' }), /Plan duration/);
  assert.throws(() => normalizeBookingTicket({ ...booking, durationMinutes: 30,
    planEnd: '2099-09-09T09:45:00+05:00' }), /must match/);
  assert.throws(() => normalizeBookingTicket({ ...booking, durationMinutes: 15,
    planEnd: '2099-09-09T09:15:01+05:00' }), /Plan duration/);
  const ticket = normalizeBookingTicket(booking);
  for (const patch of [{ DurationMinutes: 375 }, { DurationMinutes: 360.5 }, { DurationMinutes: 30 },
    { PlanEnd: '2099-09-09T15:15:00+05:00', DurationMinutes: 375 }]) {
    assert.equal(normalizeAndValidateTicket({ ...ticket, ...patch }).ok, false);
  }
  assert.equal(normalizeAndValidateIdentTicket({ ...ticket, PlanEnd: '2099-09-09T15:15:00+05:00' }).ok, false);
});

test('birth date reaches the robot ticket and official IDENT Comment without extending its schema', () => {
  const ticket = normalizeBookingTicket({ ...booking, comment: 'Patient comment' });
  assert.equal(normalizeAndValidateTicket(ticket).ticket.ClientBirthDate, '2000-02-29');
  const outgoing = normalizeAndValidateIdentTicket(ticket);
  assert.equal(outgoing.ok, true);
  assert.equal(outgoing.ticket.ClientBirthDate, undefined);
  assert.equal(outgoing.ticket.Comment, 'Patient comment\nДата рождения: 29.02.2000');
  assert.equal(normalizeAndValidateIdentTicket({ ...ticket, Comment: outgoing.ticket.Comment }).ticket.Comment,
    outgoing.ticket.Comment);
  for (const validate of [normalizeAndValidateTicket, normalizeAndValidateIdentTicket]) {
    assert.equal(validate({ ...ticket, ClientBirthDate: '2001-02-29' }).ok, false);
  }
});
