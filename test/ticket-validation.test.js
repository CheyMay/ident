import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeAndValidateTicket, normalizePhoneForIdent } from '../src/ident/ticket-validation.js';

test('normalizes phones for IDENT tickets', () => {
  assert.deepEqual(normalizePhoneForIdent('+7 (911) 000-11-22'), {
    ok: true,
    value: '+79110001122'
  });
  assert.deepEqual(normalizePhoneForIdent('+89110001122'), {
    ok: true,
    value: '89110001122'
  });
  assert.equal(normalizePhoneForIdent('+79110001122, +79220001122').ok, false);
});

test('validates IDENT ticket contract fields', () => {
  const valid = normalizeAndValidateTicket({
    Id: 'ticket-1',
    DateAndTime: '2026-05-08T10:00:00+03:00',
    ClientPhone: '9110001122',
    ClientFullName: 'Ivan Ivanov',
    PlanStart: '2026-05-12T10:00:00+03:00',
    PlanEnd: '2026-05-12T11:00:00+03:00'
  });

  assert.equal(valid.ok, true);
  assert.equal(valid.ticket.ClientPhone, '+79110001122');

  const invalid = normalizeAndValidateTicket({
    Id: 'ticket-2',
    DateAndTime: '2026-05-08T10:00:00+03:00',
    ClientPhone: '+79110001122',
    ClientFullName: 'Ivan Ivanov',
    PlanStart: '2026-05-12T10:00:00+03:00',
    PlanEnd: '2026-05-13T00:30:00+03:00'
  });

  assert.equal(invalid.ok, false);
  assert.match(invalid.errors.join('; '), /12 hours/);
});
