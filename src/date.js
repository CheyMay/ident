export function epochSecondsToIdentDate(value) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds)) return null;
  return formatDateWithUtcOffset(new Date(seconds * 1000));
}

export function normalizeIdentDate(value) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value === 'number') return epochSecondsToIdentDate(value);

  const raw = String(value).trim();
  if (!raw) return null;

  if (/^\d+$/.test(raw)) {
    const numeric = Number(raw);
    return epochSecondsToIdentDate(raw.length > 10 ? Math.floor(numeric / 1000) : numeric);
  }

  const isoish = raw.replace(' ', 'T');
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(isoish)) return `${isoish}:00`;
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2})?$/.test(isoish)) return isoish;

  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return null;
  return formatDateWithUtcOffset(parsed);
}

export function parseDateParam(value) {
  if (!value) return null;
  const parsed = new Date(String(value));
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

export function isWithinRange(identDateValue, from, to) {
  const value = parseDateParam(identDateValue);
  if (!value) return false;
  if (from && value < from) return false;
  if (to && value > to) return false;
  return true;
}

export function addMinutes(identDateValue, minutes) {
  const parsed = parseDateParam(identDateValue);
  if (!parsed) return null;
  return formatDateWithUtcOffset(new Date(parsed.getTime() + minutes * 60_000));
}

function formatDateWithUtcOffset(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return [
    date.getUTCFullYear(),
    '-',
    pad(date.getUTCMonth() + 1),
    '-',
    pad(date.getUTCDate()),
    'T',
    pad(date.getUTCHours()),
    ':',
    pad(date.getUTCMinutes()),
    ':',
    pad(date.getUTCSeconds()),
    '+00:00'
  ].join('');
}
