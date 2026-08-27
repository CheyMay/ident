import { parseDateParam } from '../date.js';

export const SLOT_STEP_MINUTES = 15;
export const DEFAULT_RESERVATION_MINUTES = 720;

const BLOCKING_RESERVATION_STATUSES = new Set(['active', 'awaiting_timetable', 'awaiting_review']);
const RELEASED_RECORD_STATUSES = new Set(['failed', 'ignored']);

export class SlotUnavailableError extends Error {
  constructor(message = 'Выбранное время уже занято или зарезервировано. Обновите расписание.') {
    super(message);
    this.name = 'SlotUnavailableError';
    this.status = 409;
    this.code = 'slot_unavailable';
  }
}

export class TimetableStaleError extends SlotUnavailableError {
  constructor(message = 'Расписание IDENT давно не обновлялось. Дождитесь свежей выгрузки и повторите запись.') {
    super(message);
    this.name = 'TimetableStaleError';
    this.code = 'timetable_stale';
  }
}

export function bookingWindow(ticket, branchId = null) {
  const start = parseDateParam(ticket?.PlanStart);
  const end = parseDateParam(ticket?.PlanEnd);
  const doctorId = Number.parseInt(String(ticket?.DoctorId ?? ''), 10);
  const normalizedBranchId = optionalInteger(branchId);
  if (!start || !end || !Number.isInteger(doctorId)) return null;

  const durationMinutes = (end.getTime() - start.getTime()) / 60_000;
  if (
    start.getTime() % (SLOT_STEP_MINUTES * 60_000) !== 0 ||
    end.getTime() % (SLOT_STEP_MINUTES * 60_000) !== 0 ||
    !Number.isInteger(durationMinutes) ||
    durationMinutes <= 0 ||
    durationMinutes > 12 * 60 ||
    durationMinutes % SLOT_STEP_MINUTES !== 0
  ) {
    return null;
  }

  return {
    doctorId,
    branchId: normalizedBranchId,
    start,
    end,
    startAt: ticket.PlanStart,
    endAt: ticket.PlanEnd,
    durationMinutes
  };
}

export function assertTimetableFresh(timetable, maxAgeMinutes = 0, now = new Date()) {
  const allowedAge = Number(maxAgeMinutes || 0);
  if (!Number.isFinite(allowedAge) || allowedAge <= 0) return;
  const receivedAt = parseDateParam(timetable?.receivedAt);
  if (!receivedAt || now.getTime() - receivedAt.getTime() > allowedAge * 60_000) {
    throw new TimetableStaleError();
  }
}

export function assertBookableWindow({
  timetable,
  ticket,
  branchId = null,
  records = [],
  excludeId = '',
  maxTimetableAgeMinutes = 0,
  now = new Date()
}) {
  const window = bookingWindow(ticket, branchId);
  if (!window) {
    const error = new Error('Время записи должно быть задано положительным интервалом, кратным 15 минутам.');
    error.status = 400;
    throw error;
  }
  if (!timetable || !Array.isArray(timetable.Intervals)) {
    throw new SlotUnavailableError('Расписание IDENT ещё не загружено. Обновите расписание и повторите запись.');
  }
  assertTimetableFresh(timetable, maxTimetableAgeMinutes, now);

  const conflict = records.find((record) => {
    if (excludeId && String(record.id) === String(excludeId)) return false;
    const reservation = blockingReservation(record, now);
    return reservation && windowsOverlap(window, reservation);
  });
  if (conflict) throw new SlotUnavailableError();

  for (const segment of windowSegments(window)) {
    const matching = timetable.Intervals.filter((interval) => intervalMatchesSegment(interval, segment, window));
    if (!matching.length || matching.some((interval) => interval.IsBusy) || !matching.some((interval) => !interval.IsBusy)) {
      throw new SlotUnavailableError();
    }
  }
  return window;
}

export function createReservation(ticket, branchId = null, options = {}) {
  const window = bookingWindow(ticket, branchId);
  if (!window) return null;
  const now = options.now instanceof Date ? options.now : new Date();
  const requestedHoldMinutes = Number(options.holdMinutes || DEFAULT_RESERVATION_MINUTES);
  const holdMinutes = Number.isFinite(requestedHoldMinutes)
    ? Math.max(5, requestedHoldMinutes)
    : DEFAULT_RESERVATION_MINUTES;
  return {
    status: 'active',
    doctorId: window.doctorId,
    branchId: window.branchId,
    startAt: window.startAt,
    endAt: window.endAt,
    durationMinutes: window.durationMinutes,
    createdAt: now.toISOString(),
    expiresAt: new Date(now.getTime() + holdMinutes * 60_000).toISOString(),
    confirmedAt: null,
    releasedAt: null,
    releaseReason: null
  };
}

export function overlayReservations(timetable, records, now = new Date()) {
  if (!timetable || !Array.isArray(timetable.Intervals)) return timetable;
  const reservations = records
    .map((record) => ({ record, reservation: blockingReservation(record, now) }))
    .filter((item) => item.reservation);
  if (!reservations.length) return timetable;

  const intervals = timetable.Intervals.map((interval) => {
    if (interval.IsBusy) return interval;
    const intervalWindow = intervalAsWindow(interval);
    if (!intervalWindow) return interval;
    const match = reservations.find(({ reservation }) => windowsOverlap(intervalWindow, reservation));
    if (!match) return interval;
    return {
      ...interval,
      IsBusy: true,
      IsReserved: true,
      ReservationTicketId: match.record.id
    };
  });

  return {
    ...timetable,
    Intervals: intervals,
    Summary: {
      ...(timetable.Summary || {}),
      intervals: intervals.length,
      freeIntervals: intervals.filter((item) => !item.IsBusy).length,
      busyIntervals: intervals.filter((item) => item.IsBusy).length,
      reservedIntervals: intervals.filter((item) => item.IsReserved).length
    }
  };
}

export function reconcileReservations(records, timetable, now = new Date()) {
  let changed = false;
  for (const record of records) {
    const reservation = record.reservation;
    if (!reservation || !BLOCKING_RESERVATION_STATUSES.has(reservation.status)) continue;

    if (RELEASED_RECORD_STATUSES.has(record.status)) {
      releaseReservation(reservation, now, record.status);
      changed = true;
      continue;
    }

    if (timetableConfirmsBusy(timetable, reservation)) {
      reservation.status = 'confirmed';
      reservation.confirmedAt = now.toISOString();
      reservation.releasedAt = now.toISOString();
      reservation.releaseReason = 'confirmed_by_timetable';
      changed = true;
      continue;
    }

    const expiresAt = parseDateParam(reservation.expiresAt);
    if (record.status !== 'robot_processing' && expiresAt && expiresAt <= now) {
      releaseReservation(reservation, now, 'expired');
      changed = true;
    }
  }
  return changed;
}

export function blockingReservation(record, now = new Date()) {
  const reservation = record?.reservation;
  if (!reservation || !BLOCKING_RESERVATION_STATUSES.has(reservation.status)) return null;
  if (RELEASED_RECORD_STATUSES.has(record.status)) return null;
  const expiresAt = parseDateParam(reservation.expiresAt);
  if (record.status !== 'robot_processing' && expiresAt && expiresAt <= now) return null;
  const start = parseDateParam(reservation.startAt);
  const end = parseDateParam(reservation.endAt);
  if (!start || !end) return null;
  return {
    ...reservation,
    doctorId: Number.parseInt(String(reservation.doctorId), 10),
    branchId: optionalInteger(reservation.branchId),
    start,
    end
  };
}

export function releaseReservation(reservation, now = new Date(), reason = 'released') {
  if (!reservation) return;
  reservation.status = 'released';
  reservation.releasedAt = now.toISOString();
  reservation.releaseReason = reason;
}

export function extendReservation(reservation, until, status = 'active') {
  if (!reservation) return;
  const deadline = until instanceof Date ? until : parseDateParam(until);
  reservation.status = status;
  if (deadline) reservation.expiresAt = deadline.toISOString();
  reservation.releasedAt = null;
  reservation.releaseReason = null;
}

function windowSegments(window) {
  const segments = [];
  for (let start = window.start.getTime(); start < window.end.getTime(); start += SLOT_STEP_MINUTES * 60_000) {
    segments.push({ start: new Date(start), end: new Date(start + SLOT_STEP_MINUTES * 60_000) });
  }
  return segments;
}

function intervalMatchesSegment(interval, segment, window) {
  const intervalWindow = intervalAsWindow(interval);
  if (!intervalWindow) return false;
  if (intervalWindow.doctorId !== window.doctorId) return false;
  if (window.branchId !== null && intervalWindow.branchId !== window.branchId) return false;
  return intervalWindow.start <= segment.start && intervalWindow.end >= segment.end;
}

function intervalAsWindow(interval) {
  const start = parseDateParam(interval?.StartDateTime);
  const durationMinutes = Number.parseInt(String(interval?.LengthInMinutes ?? ''), 10);
  const doctorId = Number.parseInt(String(interval?.DoctorId ?? ''), 10);
  if (!start || !Number.isInteger(durationMinutes) || durationMinutes <= 0 || !Number.isInteger(doctorId)) return null;
  return {
    doctorId,
    branchId: optionalInteger(interval.BranchId),
    start,
    end: new Date(start.getTime() + durationMinutes * 60_000)
  };
}

function windowsOverlap(left, right) {
  if (Number(left.doctorId) !== Number(right.doctorId)) return false;
  if (left.branchId !== null && right.branchId !== null && Number(left.branchId) !== Number(right.branchId)) return false;
  return left.start < right.end && right.start < left.end;
}

function timetableConfirmsBusy(timetable, reservation) {
  if (!timetable || !Array.isArray(timetable.Intervals)) return false;
  const window = blockingReservation({ status: 'robot_processing', reservation });
  if (!window) return false;
  return windowSegments(window).every((segment) => timetable.Intervals.some((interval) => {
    return Boolean(interval.IsBusy) && intervalMatchesSegment(interval, segment, window);
  }));
}

function optionalInteger(value) {
  if (value === undefined || value === null || String(value).trim() === '') return null;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isInteger(parsed) ? parsed : null;
}
