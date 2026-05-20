const AMO_INT_KEYS = [
  'pipelineId',
  'statusId',
  'createPipelineId',
  'createStatusId',
  'sentStatusId',
  'failedStatusId',
  'timetableCatalogId'
];

const AMO_FIELD_KEYS = [
  'planStart',
  'planEnd',
  'doctorId',
  'doctorName',
  'doctorAmoId',
  'comment',
  'formName',
  'utmSource',
  'utmMedium',
  'utmCampaign',
  'utmTerm',
  'utmContent',
  'httpReferer'
];

const AMO_TIMETABLE_FIELD_KEYS = [
  'start',
  'end',
  'doctorId',
  'doctorName',
  'branchId',
  'branchName',
  'isBusy',
  'identKey'
];

export class SettingsStore {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'settings.json';
  }

  async get() {
    return normalizeSettings(await this.storage.readJson(this.fileName, null));
  }

  async merge(patch) {
    const current = await this.get();
    const merged = normalizeSettings({
      ...current,
      amo: mergeAmo(current.amo, patch?.amo),
      dedupe: mergeDedupe(current.dedupe, patch?.dedupe),
      updatedAt: new Date().toISOString()
    });
    await this.storage.writeJson(this.fileName, merged);
    return merged;
  }
}

export function buildEffectiveConfig(baseConfig, settings) {
  const normalized = normalizeSettings(settings);
  return {
    ...baseConfig,
    amo: {
      ...baseConfig.amo,
      ...pickDefinedInts(normalized.amo, AMO_INT_KEYS),
      fields: {
        ...baseConfig.amo.fields,
        ...pickDefinedInts(normalized.amo.fields, AMO_FIELD_KEYS)
      },
      timetableFields: {
        ...baseConfig.amo.timetableFields,
        ...pickDefinedInts(normalized.amo.timetableFields, AMO_TIMETABLE_FIELD_KEYS)
      },
      rateLimit: {
        ...baseConfig.amo.rateLimit,
        ...pickDefinedInts(normalized.amo.rateLimit, ['minDelayMs', 'maxRetries', 'retryBaseDelayMs'])
      }
    },
    dedupe: {
      ...baseConfig.dedupe,
      ...normalized.dedupe
    }
  };
}

export function normalizeSettings(data) {
  return {
    updatedAt: data?.updatedAt || null,
    amo: mergeAmo({}, data?.amo),
    dedupe: mergeDedupe({}, data?.dedupe)
  };
}

function mergeAmo(current = {}, patch = {}) {
  return {
    ...current,
    ...pickDefinedInts(patch, AMO_INT_KEYS),
    fields: {
      ...(current.fields || {}),
      ...pickDefinedInts(patch.fields, AMO_FIELD_KEYS)
    },
    timetableFields: {
      ...(current.timetableFields || {}),
      ...pickDefinedInts(patch.timetableFields, AMO_TIMETABLE_FIELD_KEYS)
    },
    rateLimit: {
      ...(current.rateLimit || {}),
      ...pickDefinedInts(patch.rateLimit, ['minDelayMs', 'maxRetries', 'retryBaseDelayMs'])
    }
  };
}

function mergeDedupe(current = {}, patch = {}) {
  const result = {};
  if (current.enabled !== undefined) result.enabled = Boolean(current.enabled);
  if (current.windowMinutes !== undefined) result.windowMinutes = optionalPositiveInt(current.windowMinutes);
  if (patch.enabled !== undefined) result.enabled = Boolean(patch.enabled);
  if (patch.windowMinutes !== undefined) result.windowMinutes = optionalPositiveInt(patch.windowMinutes);
  return result;
}

function pickDefinedInts(source = {}, keys) {
  const result = {};
  for (const key of keys) {
    if (source[key] === undefined || source[key] === null || source[key] === '') continue;
    const parsed = Number.parseInt(String(source[key]), 10);
    if (Number.isFinite(parsed)) result[key] = parsed;
  }
  return result;
}

function optionalPositiveInt(value) {
  if (value === undefined || value === null || value === '') return undefined;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}
