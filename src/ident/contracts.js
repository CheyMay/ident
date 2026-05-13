import { addMinutes, isWithinRange, normalizeIdentDate } from '../date.js';

export function validateIdentKey(req, config) {
  if (!config.identIntegrationKey) {
    return { ok: false, status: 500, message: 'IDENT_INTEGRATION_KEY is not configured' };
  }

  const actual = req.headers['ident-integration-key'];
  if (actual !== config.identIntegrationKey) {
    return { ok: false, status: 401, message: 'Invalid IDENT integration key' };
  }

  return { ok: true };
}

export function normalizeTimeTablePayload(payload) {
  if (!payload || typeof payload !== 'object') {
    throw new BadRequestError('Request body must be a JSON object');
  }

  const doctors = normalizeNamedEntities(payload.Doctors, 'Doctors');
  const branches = normalizeNamedEntities(payload.Branches, 'Branches');
  const intervals = normalizeIntervals(payload.Intervals);

  return {
    receivedAt: new Date().toISOString(),
    Doctors: doctors,
    Branches: branches,
    Intervals: intervals,
    Summary: {
      doctors: doctors.length,
      branches: branches.length,
      intervals: intervals.length,
      freeIntervals: intervals.filter((item) => !item.IsBusy).length,
      busyIntervals: intervals.filter((item) => item.IsBusy).length
    }
  };
}

export function filterTickets(tickets, { from, to, limit, offset }) {
  const start = Number.isFinite(offset) ? offset : 0;
  const count = Number.isFinite(limit) ? limit : tickets.length;
  return tickets
    .filter((ticket) => isWithinRange(ticket.DateAndTime, from, to))
    .sort((left, right) => String(left.DateAndTime).localeCompare(String(right.DateAndTime)))
    .slice(start, start + count);
}

export function normalizeBookingTicket(input, options = {}) {
  const now = new Date().toISOString();
  const planStart = normalizeIdentDate(input.planStart ?? input.PlanStart ?? input.start);
  const planEnd =
    normalizeIdentDate(input.planEnd ?? input.PlanEnd ?? input.end) ||
    (planStart ? addMinutes(planStart, options.defaultAppointmentMinutes || 60) : null);

  const ticket = stripEmpty({
    Id: String(input.id ?? input.Id ?? `local:${Date.now()}`),
    DateAndTime: normalizeIdentDate(input.dateAndTime ?? input.DateAndTime) || normalizeIdentDate(now),
    ClientPhone: input.clientPhone ?? input.ClientPhone ?? input.phone,
    ClientEmail: input.clientEmail ?? input.ClientEmail ?? input.email,
    FormName: input.formName ?? input.FormName ?? 'amoCRM',
    ClientFullName: input.clientFullName ?? input.ClientFullName ?? input.name,
    PlanStart: planStart,
    PlanEnd: planEnd,
    Comment: input.comment ?? input.Comment,
    DoctorId: input.doctorId ?? input.DoctorId,
    DoctorName: input.doctorName ?? input.DoctorName,
    UtmSource: input.utmSource ?? input.UtmSource,
    UtmMedium: input.utmMedium ?? input.UtmMedium,
    UtmCampaign: input.utmCampaign ?? input.UtmCampaign,
    UtmTerm: input.utmTerm ?? input.UtmTerm,
    UtmContent: input.utmContent ?? input.UtmContent,
    HttpReferer: input.httpReferer ?? input.HttpReferer
  });

  if (!ticket.ClientPhone) {
    throw new BadRequestError('clientPhone is required');
  }

  if (!ticket.ClientFullName) {
    throw new BadRequestError('clientFullName or name is required');
  }

  if (ticket.PlanStart && !ticket.PlanEnd) {
    throw new BadRequestError('planEnd is required when planStart cannot be normalized');
  }

  return ticket;
}

export function stripEmpty(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, item]) => item !== undefined && item !== null && item !== '')
  );
}

export class BadRequestError extends Error {
  constructor(message) {
    super(message);
    this.name = 'BadRequestError';
    this.status = 400;
  }
}

function normalizeNamedEntities(items, name) {
  if (!Array.isArray(items)) throw new BadRequestError(`${name} must be an array`);
  return items.map((item, index) => {
    const id = Number.parseInt(item?.Id, 10);
    const title = String(item?.Name || '').trim();
    if (!Number.isFinite(id)) throw new BadRequestError(`${name}[${index}].Id must be an integer`);
    if (!title) throw new BadRequestError(`${name}[${index}].Name is required`);
    return { Id: id, Name: title };
  });
}

function normalizeIntervals(items) {
  if (!Array.isArray(items)) throw new BadRequestError('Intervals must be an array');
  return items.map((item, index) => {
    const doctorId = Number.parseInt(item?.DoctorId, 10);
    const branchId = Number.parseInt(item?.BranchId, 10);
    const length = Number.parseInt(item?.LengthInMinutes, 10);
    const start = normalizeIdentDate(item?.StartDateTime);
    if (!Number.isFinite(doctorId)) throw new BadRequestError(`Intervals[${index}].DoctorId must be an integer`);
    if (!Number.isFinite(branchId)) throw new BadRequestError(`Intervals[${index}].BranchId must be an integer`);
    if (!start) throw new BadRequestError(`Intervals[${index}].StartDateTime must be a date`);
    if (!Number.isFinite(length) || length <= 0) {
      throw new BadRequestError(`Intervals[${index}].LengthInMinutes must be a positive integer`);
    }
    return {
      DoctorId: doctorId,
      BranchId: branchId,
      StartDateTime: start,
      LengthInMinutes: length,
      IsBusy: item?.IsBusy === true || item?.IsBusy === 1 || item?.IsBusy === '1'
    };
  });
}
