export class MappingStore {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'mappings.json';
  }

  async get() {
    const data = await this.storage.readJson(this.fileName, null);
    return normalizeMappings(data);
  }

  async syncFromTimetable(timetable) {
    const mappings = await this.get();
    const now = new Date().toISOString();
    mappings.doctors = syncIdentEntities(mappings.doctors, timetable.Doctors || [], now);
    mappings.branches = syncIdentEntities(mappings.branches, timetable.Branches || [], now);
    mappings.updatedAt = now;
    await this.write(mappings);
    return mappings;
  }

  async merge(patch) {
    const mappings = await this.get();
    const now = new Date().toISOString();
    mappings.doctors = mergeEntities(mappings.doctors, patch?.doctors || [], now);
    mappings.branches = mergeEntities(mappings.branches, patch?.branches || [], now);
    mappings.updatedAt = now;
    await this.write(mappings);
    return mappings;
  }

  async resolveDoctor({ identId, name, amoId }) {
    const mappings = await this.get();
    return resolveEntity(mappings.doctors, { identId, name, amoId });
  }

  async write(mappings) {
    await this.storage.writeJson(this.fileName, normalizeMappings(mappings));
  }
}

export async function applyDoctorMapping(ticket, mappingStore, options = {}) {
  const inputId = optionalInt(ticket.DoctorId);
  const inputName = ticket.DoctorName ? String(ticket.DoctorName).trim() : '';
  const resolved = await mappingStore.resolveDoctor({
    identId: inputId,
    name: inputName,
    amoId: options.amoDoctorId
  });

  if (resolved) {
    ticket.DoctorId = resolved.identId;
    ticket.DoctorName = resolved.identName;
    return { ok: true, resolved };
  }

  if (options.requireDoctorMapping) {
    return {
      ok: false,
      reason: `Doctor mapping was not found for ${inputName || inputId || 'empty doctor'}`
    };
  }

  if (inputId) ticket.DoctorId = inputId;
  return { ok: true, resolved: null };
}

function normalizeMappings(data) {
  return {
    updatedAt: data?.updatedAt || null,
    doctors: normalizeEntities(data?.doctors || []),
    branches: normalizeEntities(data?.branches || [])
  };
}

function normalizeEntities(items) {
  return items
    .map((item) => {
      const identId = optionalInt(item.identId ?? item.Id);
      const identName = String(item.identName ?? item.Name ?? '').trim();
      if (!identId || !identName) return null;
      return {
        identId,
        identName,
        aliases: uniqueStrings(item.aliases || []),
        amoIds: uniqueStrings(item.amoIds || []),
        amoNames: uniqueStrings(item.amoNames || []),
        lastSeenAt: item.lastSeenAt || null,
        updatedAt: item.updatedAt || null
      };
    })
    .filter(Boolean)
    .sort((left, right) => left.identName.localeCompare(right.identName));
}

function syncIdentEntities(existing, identItems, now) {
  const byId = new Map(existing.map((item) => [item.identId, item]));
  for (const identItem of identItems) {
    const identId = optionalInt(identItem.Id);
    const identName = String(identItem.Name || '').trim();
    if (!identId || !identName) continue;
    const current = byId.get(identId);
    byId.set(identId, {
      identId,
      identName,
      aliases: current?.aliases || [],
      amoIds: current?.amoIds || [],
      amoNames: current?.amoNames || [],
      lastSeenAt: now,
      updatedAt: current?.updatedAt || now
    });
  }
  return normalizeEntities([...byId.values()]);
}

function mergeEntities(existing, patchItems, now) {
  const byId = new Map(existing.map((item) => [item.identId, item]));
  for (const patch of patchItems) {
    const identId = optionalInt(patch.identId ?? patch.Id);
    if (!identId) continue;
    const current = byId.get(identId);
    const identName = String(patch.identName ?? patch.Name ?? current?.identName ?? '').trim();
    if (!identName) continue;
    byId.set(identId, {
      identId,
      identName,
      aliases: uniqueStrings([...(current?.aliases || []), ...(patch.aliases || [])]),
      amoIds: uniqueStrings([...(current?.amoIds || []), ...(patch.amoIds || [])]),
      amoNames: uniqueStrings([...(current?.amoNames || []), ...(patch.amoNames || [])]),
      lastSeenAt: current?.lastSeenAt || null,
      updatedAt: now
    });
  }
  return normalizeEntities([...byId.values()]);
}

function resolveEntity(items, { identId, name, amoId }) {
  const numericId = optionalInt(identId);
  if (numericId) {
    const direct = items.find((item) => item.identId === numericId);
    if (direct) return direct;
  }

  const amoIdText = amoId === undefined || amoId === null ? '' : String(amoId).trim();
  if (amoIdText) {
    const byAmoId = items.find((item) => item.amoIds.includes(amoIdText));
    if (byAmoId) return byAmoId;
  }

  const normalizedName = normalizeName(name);
  if (normalizedName) {
    return (
      items.find((item) => normalizeName(item.identName) === normalizedName) ||
      items.find((item) => item.aliases.some((alias) => normalizeName(alias) === normalizedName)) ||
      items.find((item) => item.amoNames.some((amoName) => normalizeName(amoName) === normalizedName)) ||
      null
    );
  }

  return null;
}

function optionalInt(value) {
  if (value === undefined || value === null || String(value).trim() === '') return null;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function uniqueStrings(items) {
  return [...new Set(items.map((item) => String(item).trim()).filter(Boolean))];
}

function normalizeName(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/ё/g, 'е')
    .replace(/[^a-zа-я0-9]+/gi, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}
