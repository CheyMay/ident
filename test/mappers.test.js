import assert from 'node:assert/strict';
import test from 'node:test';
import { loadConfig } from '../src/config.js';
import { normalizeTimeTablePayload, normalizeBookingTicket } from '../src/ident/contracts.js';
import { bookingToAmoLead, leadToIdentTicket } from '../src/ident/mappers.js';

test('normalizes IDENT timetable payload', () => {
  const result = normalizeTimeTablePayload({
    Doctors: [{ Id: '2129', Name: 'Иванов Виталий Сергеевич' }],
    Branches: [{ Id: '1', Name: 'Филиал' }],
    Intervals: [
      {
        DoctorId: '2129',
        BranchId: '1',
        StartDateTime: '2026-05-12T10:00:00+03:00',
        LengthInMinutes: '60',
        IsBusy: '0'
      }
    ]
  });

  assert.equal(result.Summary.doctors, 1);
  assert.equal(result.Summary.freeIntervals, 1);
  assert.deepEqual(result.Intervals[0], {
    DoctorId: 2129,
    BranchId: 1,
    StartDateTime: '2026-05-12T10:00:00+03:00',
    LengthInMinutes: 60,
    IsBusy: false
  });
});

test('maps amoCRM lead and contact to IDENT ticket', () => {
  const config = loadConfig({
    AMOCRM_FIELD_PLAN_START_ID: '1001',
    AMOCRM_FIELD_PLAN_END_ID: '1002',
    AMOCRM_FIELD_DOCTOR_ID_ID: '1003',
    AMOCRM_FIELD_DOCTOR_NAME_ID: '1004',
    AMOCRM_FIELD_COMMENT_ID: '1005'
  });
  const lead = {
    id: 123,
    name: 'Заявка',
    created_at: 1770000000,
    updated_at: 1770000300,
    custom_fields_values: [
      { field_id: 1001, values: [{ value: '2026-05-12T10:00:00+03:00' }] },
      { field_id: 1002, values: [{ value: '2026-05-12T11:00:00+03:00' }] },
      { field_id: 1003, values: [{ value: '2129' }] },
      { field_id: 1004, values: [{ value: 'Иванов Виталий Сергеевич' }] },
      { field_id: 1005, values: [{ value: 'Первичный прием' }] }
    ]
  };
  const contact = {
    id: 456,
    name: 'Петров Петр',
    custom_fields_values: [
      { field_code: 'PHONE', values: [{ value: '+79110001122' }] },
      { field_code: 'EMAIL', values: [{ value: 'petrov@example.ru' }] }
    ]
  };

  const ticket = leadToIdentTicket(lead, contact, config);

  assert.equal(ticket.Id, 'amo:123');
  assert.equal(ticket.ClientPhone, '+79110001122');
  assert.equal(ticket.ClientEmail, 'petrov@example.ru');
  assert.equal(ticket.ClientFullName, 'Петров Петр');
  assert.equal(ticket.PlanStart, '2026-05-12T10:00:00+03:00');
  assert.equal(ticket.PlanEnd, '2026-05-12T11:00:00+03:00');
  assert.equal(ticket.DoctorId, 2129);
});

test('normalizes booking and maps it to amoCRM complex lead', () => {
  const config = loadConfig({
    AMOCRM_FIELD_PLAN_START_ID: '1001',
    AMOCRM_FIELD_PLAN_END_ID: '1002',
    AMOCRM_FIELD_DOCTOR_ID_ID: '1003',
    AMOCRM_FIELD_DOCTOR_NAME_ID: '1004',
    AMOCRM_CREATE_PIPELINE_ID: '10',
    AMOCRM_CREATE_STATUS_ID: '20',
    AMOCRM_CREATE_TAG: 'IDENT'
  });

  const ticket = normalizeBookingTicket(
    {
      id: 'test-1',
      clientFullName: 'Иванов Иван',
      clientPhone: '+79110001122',
      planStart: '2026-05-12T10:00:00+03:00',
      doctorId: 2129,
      doctorName: 'Иванов Виталий Сергеевич'
    },
    { defaultAppointmentMinutes: 45 }
  );
  const lead = bookingToAmoLead(ticket, config);

  assert.equal(ticket.PlanEnd, '2026-05-12T07:45:00+00:00');
  assert.equal(lead.pipeline_id, 10);
  assert.equal(lead.status_id, 20);
  assert.equal(lead._embedded.contacts[0].name, 'Иванов Иван');
  assert.equal(lead._embedded.contacts[0].custom_fields_values[0].field_code, 'PHONE');
  assert.deepEqual(
    lead.custom_fields_values.map((field) => field.field_id),
    [1001, 1002, 1003, 1004]
  );
});
