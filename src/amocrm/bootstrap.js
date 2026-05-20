const DEFAULT_LEAD_FIELDS = [
  { key: 'planStart', name: 'IDENT: Дата записи', type: 'date_time', sort: 510 },
  { key: 'planEnd', name: 'IDENT: Окончание записи', type: 'date_time', sort: 520 },
  { key: 'doctorId', name: 'IDENT: ID врача', type: 'numeric', sort: 530 },
  { key: 'doctorName', name: 'IDENT: Врач', type: 'text', sort: 540 },
  { key: 'comment', name: 'IDENT: Комментарий', type: 'textarea', sort: 550 },
  { key: 'formName', name: 'IDENT: Источник', type: 'text', sort: 560 }
];

const DEFAULT_STATUSES = [
  { key: 'sentStatusId', name: 'Передано в IDENT', color: '#99ccff', sort: 900 },
  { key: 'failedStatusId', name: 'Ошибка IDENT', color: '#ff8f92', sort: 910 }
];

export async function bootstrapAmoDefaults({ config, amoClient, settingsStore }) {
  const [leadFields, pipelines] = await Promise.all([
    amoClient.listLeadCustomFields(),
    amoClient.listPipelines()
  ]);

  const fieldResult = await ensureLeadFields({ amoClient, existingFields: leadFields });
  const pipelineId = config.amo.pipelineId || pipelines.find((pipeline) => pipeline.isMain)?.id || pipelines[0]?.id || null;
  const statusResult = pipelineId
    ? await ensureStatuses({ amoClient, existingPipelines: pipelines, pipelineId })
    : { created: [], matched: [], settings: {} };

  const settingsPatch = {
    amo: {
      pipelineId,
      fields: fieldResult.settings,
      ...statusResult.settings
    }
  };
  const settings = await settingsStore.merge(settingsPatch);

  return {
    settings,
    fields: {
      created: fieldResult.created,
      matched: fieldResult.matched
    },
    statuses: {
      pipelineId,
      created: statusResult.created,
      matched: statusResult.matched
    }
  };
}

async function ensureLeadFields({ amoClient, existingFields }) {
  const matched = [];
  const missing = [];
  const settings = {};

  for (const spec of DEFAULT_LEAD_FIELDS) {
    const existing = existingFields.find((field) => normalizeName(field.name) === normalizeName(spec.name));
    if (existing) {
      matched.push(summarizeField(existing, spec.key));
      settings[spec.key] = existing.id;
    } else {
      missing.push({
        name: spec.name,
        type: spec.type,
        sort: spec.sort,
        request_id: spec.key
      });
    }
  }

  const createdRaw = await amoClient.createLeadCustomFields(missing);
  const created = createdRaw.map((field) => summarizeField(field, field.request_id));
  for (const field of created) {
    if (field.key) settings[field.key] = field.id;
  }

  return { matched, created, settings };
}

async function ensureStatuses({ amoClient, existingPipelines, pipelineId }) {
  const pipeline = existingPipelines.find((item) => Number(item.id) === Number(pipelineId));
  const existingStatuses = pipeline?._embedded?.statuses || pipeline?.statuses || [];
  const matched = [];
  const missing = [];
  const settings = {};

  for (const spec of DEFAULT_STATUSES) {
    const existing = existingStatuses.find((status) => normalizeName(status.name) === normalizeName(spec.name));
    if (existing) {
      matched.push(summarizeStatus(existing, spec.key));
      settings[spec.key] = existing.id;
    } else {
      missing.push({
        name: spec.name,
        color: spec.color,
        sort: spec.sort,
        request_id: spec.key
      });
    }
  }

  const createdRaw = await amoClient.createPipelineStatuses(pipelineId, missing);
  const created = createdRaw.map((status) => summarizeStatus(status, status.request_id));
  for (const status of created) {
    if (status.key) settings[status.key] = status.id;
  }

  return { matched, created, settings };
}

function summarizeField(field, key) {
  return {
    key,
    id: field.id,
    name: field.name,
    type: field.type || null
  };
}

function summarizeStatus(status, key) {
  return {
    key,
    id: status.id,
    name: status.name,
    pipelineId: status.pipeline_id || null
  };
}

function normalizeName(value) {
  return String(value || '').toLowerCase().replace(/\s+/g, ' ').trim();
}
