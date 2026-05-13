import { addMinutes } from '../date.js';

export async function syncTimetableToAmoCatalog({ timetable, amoClient, slotStore, config }) {
  if (!amoClient || !config.amo.syncTimetableToCatalog || !config.amo.timetableCatalogId) {
    return { enabled: false, created: 0, updated: 0, skipped: 0 };
  }

  const doctors = new Map(timetable.Doctors.map((item) => [item.Id, item]));
  const branches = new Map(timetable.Branches.map((item) => [item.Id, item]));
  const currentMap = await slotStore.getMap();
  const intervals = timetable.Intervals
    .filter((item) => {
      if (!config.amo.timetableSyncFreeOnly) return true;
      return !item.IsBusy || Boolean(currentMap[slotKey(item)]);
    })
    .slice(0, config.amo.timetableMaxSync);

  const creates = [];
  const updates = [];
  const keys = [];

  for (const interval of intervals) {
    const key = slotKey(interval);
    const element = slotToCatalogElement({
      interval,
      doctor: doctors.get(interval.DoctorId),
      branch: branches.get(interval.BranchId),
      fields: config.amo.timetableFields,
      requestId: key
    });
    keys.push(key);
    if (currentMap[key]) {
      updates.push({ id: currentMap[key], ...element });
    } else {
      creates.push(element);
    }
  }

  const created = await amoClient.createCatalogElements(config.amo.timetableCatalogId, creates);
  const updated = await amoClient.updateCatalogElements(config.amo.timetableCatalogId, updates);

  for (const element of created) {
    if (element.request_id) currentMap[element.request_id] = element.id;
  }
  await slotStore.setMap(currentMap);

  return {
    enabled: true,
    created: created.length,
    updated: updated.length,
    skipped: Math.max(0, timetable.Intervals.length - keys.length)
  };
}

export function slotToCatalogElement({ interval, doctor, branch, fields, requestId }) {
  const end = addMinutes(interval.StartDateTime, interval.LengthInMinutes);
  const doctorName = doctor?.Name || `Doctor ${interval.DoctorId}`;
  const branchName = branch?.Name || `Branch ${interval.BranchId}`;
  const busyLabel = interval.IsBusy ? 'busy' : 'free';
  const name = `${interval.StartDateTime} ${doctorName} (${branchName}) ${busyLabel}`;
  const customFields = [];

  addField(customFields, fields.start, interval.StartDateTime);
  addField(customFields, fields.end, end);
  addField(customFields, fields.doctorId, interval.DoctorId);
  addField(customFields, fields.doctorName, doctorName);
  addField(customFields, fields.branchId, interval.BranchId);
  addField(customFields, fields.branchName, branchName);
  addField(customFields, fields.isBusy, interval.IsBusy ? '1' : '0');
  addField(customFields, fields.identKey, requestId);

  return {
    name,
    request_id: requestId,
    ...(customFields.length ? { custom_fields_values: customFields } : {})
  };
}

function slotKey(interval) {
  return `${interval.BranchId}:${interval.DoctorId}:${interval.StartDateTime}`;
}

function addField(collection, fieldId, value) {
  if (!fieldId || value === undefined || value === null || value === '') return;
  collection.push({
    field_id: Number(fieldId),
    values: [{ value }]
  });
}
