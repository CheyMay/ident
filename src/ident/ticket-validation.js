import { parseDateParam } from '../date.js';
import { stripEmpty } from './contracts.js';

const MAX_TICKET_ID_LENGTH = 400;
const MAX_APPOINTMENT_MS = 12 * 60 * 60 * 1000;

const TICKET_FIELDS = [
  'Id',
  'DateAndTime',
  'ClientPhone',
  'ClientEmail',
  'FormName',
  'ClientFullName',
  'ClientSurname',
  'ClientName',
  'ClientPatronymic',
  'PlanStart',
  'PlanEnd',
  'Comment',
  'DoctorId',
  'DoctorName',
  'UtmSource',
  'UtmMedium',
  'UtmCampaign',
  'UtmTerm',
  'UtmContent',
  'HttpReferer'
];

export function normalizeAndValidateTicket(ticket) {
  const normalized = normalizeTicket(ticket);
  const errors = validateTicket(normalized);
  return {
    ok: errors.length === 0,
    errors,
    ticket: normalized
  };
}

export function normalizePhoneForIdent(value) {
  const raw = String(value || '').trim();
  if (!raw) return { ok: false, error: 'ClientPhone is required' };

  const withoutExtension = raw
    .replace(/\b(?:доб\.?|ext\.?|extension)\s*\d+$/i, '')
    .trim();
  const candidates = withoutExtension.match(/(?:\+?\d|\(\d)[\d\s().-]{5,}\d/g) || [];
  if (candidates.length > 1) {
    return { ok: false, error: 'ClientPhone must contain exactly one phone number' };
  }

  const candidate = candidates[0] || withoutExtension;
  if (/[a-zа-я]/i.test(candidate)) {
    return { ok: false, error: 'ClientPhone must not contain text' };
  }

  const plusCount = (candidate.match(/\+/g) || []).length;
  if (plusCount > 1 || (plusCount === 1 && !candidate.trim().startsWith('+'))) {
    return { ok: false, error: 'ClientPhone contains invalid plus sign position' };
  }

  const digits = candidate.replace(/\D/g, '');
  if (digits.length < 10 || digits.length > 15) {
    return { ok: false, error: 'ClientPhone must be a full phone number' };
  }

  if (candidate.trim().startsWith('+89')) {
    return { ok: true, value: digits };
  }

  if (digits.length === 10 && digits.startsWith('9')) {
    return { ok: true, value: `+7${digits}` };
  }

  if (digits.length === 11 && digits.startsWith('7')) {
    return { ok: true, value: `+${digits}` };
  }

  if (digits.length === 11 && digits.startsWith('8')) {
    return { ok: true, value: digits };
  }

  if (candidate.trim().startsWith('+')) {
    return { ok: true, value: `+${digits}` };
  }

  return { ok: true, value: digits };
}

function normalizeTicket(ticket) {
  const normalized = {};
  for (const field of TICKET_FIELDS) {
    if (ticket[field] !== undefined && ticket[field] !== null && ticket[field] !== '') {
      normalized[field] = ticket[field];
    }
  }

  if (normalized.Id !== undefined) normalized.Id = String(normalized.Id);
  if (normalized.ClientPhone !== undefined) {
    const phone = normalizePhoneForIdent(normalized.ClientPhone);
    if (phone.ok) normalized.ClientPhone = phone.value;
  }
  if (normalized.DoctorId !== undefined) {
    const doctorId = Number.parseInt(String(normalized.DoctorId), 10);
    if (Number.isFinite(doctorId)) normalized.DoctorId = doctorId;
  }

  return stripEmpty(normalized);
}

function validateTicket(ticket) {
  const errors = [];
  if (!ticket.Id) errors.push('Id is required');
  else if (String(ticket.Id).length > MAX_TICKET_ID_LENGTH) errors.push('Id must be 400 characters or shorter');

  if (!parseDateParam(ticket.DateAndTime)) errors.push('DateAndTime must be a valid date');

  const phone = normalizePhoneForIdent(ticket.ClientPhone);
  if (!phone.ok) errors.push(phone.error);

  const hasFullName = Boolean(String(ticket.ClientFullName || '').trim());
  const hasParts = Boolean(String(ticket.ClientSurname || ticket.ClientName || ticket.ClientPatronymic || '').trim());
  if (!hasFullName && !hasParts) errors.push('ClientFullName or client name parts are required');
  if (hasFullName && hasParts) {
    errors.push('ClientFullName must not be combined with ClientSurname, ClientName or ClientPatronymic');
  }

  const planStart = ticket.PlanStart ? parseDateParam(ticket.PlanStart) : null;
  const planEnd = ticket.PlanEnd ? parseDateParam(ticket.PlanEnd) : null;
  if (ticket.PlanStart && !planStart) errors.push('PlanStart must be a valid date');
  if (ticket.PlanEnd && !planEnd) errors.push('PlanEnd must be a valid date');
  if (planStart && planEnd) {
    if (planStart > planEnd) errors.push('PlanStart must not be later than PlanEnd');
    if (planEnd.getTime() - planStart.getTime() > MAX_APPOINTMENT_MS) {
      errors.push('Plan duration must not exceed 12 hours');
    }
  }

  if (ticket.DoctorId !== undefined && !Number.isInteger(Number(ticket.DoctorId))) {
    errors.push('DoctorId must be an integer');
  }

  return [...new Set(errors)];
}
