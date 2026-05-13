const LEAD_FIELD_BINDINGS = [
  {
    env: 'AMOCRM_FIELD_PLAN_START_ID',
    key: 'planStart',
    purpose: 'IDENT PlanStart from amoCRM lead',
    importance: 'required_for_import'
  },
  {
    env: 'AMOCRM_FIELD_PLAN_END_ID',
    key: 'planEnd',
    purpose: 'IDENT PlanEnd from amoCRM lead',
    importance: 'optional'
  },
  {
    env: 'AMOCRM_FIELD_DOCTOR_ID_ID',
    key: 'doctorId',
    purpose: 'IDENT DoctorId from amoCRM lead',
    importance: 'recommended'
  },
  {
    env: 'AMOCRM_FIELD_DOCTOR_AMO_ID_ID',
    key: 'doctorAmoId',
    purpose: 'amoCRM doctor ID for mapping to IDENT doctor',
    importance: 'optional'
  },
  {
    env: 'AMOCRM_FIELD_DOCTOR_NAME_ID',
    key: 'doctorName',
    purpose: 'Doctor name alias for IDENT mapping',
    importance: 'optional'
  },
  {
    env: 'AMOCRM_FIELD_COMMENT_ID',
    key: 'comment',
    purpose: 'IDENT Comment from amoCRM lead',
    importance: 'optional'
  },
  {
    env: 'AMOCRM_FIELD_FORM_NAME_ID',
    key: 'formName',
    purpose: 'IDENT FormName from amoCRM lead',
    importance: 'optional'
  },
  { env: 'AMOCRM_FIELD_UTM_SOURCE_ID', key: 'utmSource', purpose: 'UTM source', importance: 'optional' },
  { env: 'AMOCRM_FIELD_UTM_MEDIUM_ID', key: 'utmMedium', purpose: 'UTM medium', importance: 'optional' },
  { env: 'AMOCRM_FIELD_UTM_CAMPAIGN_ID', key: 'utmCampaign', purpose: 'UTM campaign', importance: 'optional' },
  { env: 'AMOCRM_FIELD_UTM_TERM_ID', key: 'utmTerm', purpose: 'UTM term', importance: 'optional' },
  { env: 'AMOCRM_FIELD_UTM_CONTENT_ID', key: 'utmContent', purpose: 'UTM content', importance: 'optional' },
  { env: 'AMOCRM_FIELD_HTTP_REFERER_ID', key: 'httpReferer', purpose: 'HTTP referer', importance: 'optional' }
];

const PIPELINE_BINDINGS = [
  { env: 'AMOCRM_PIPELINE_ID', key: 'pipelineId', purpose: 'amoCRM import/filter pipeline' },
  { env: 'AMOCRM_STATUS_ID', key: 'statusId', purpose: 'amoCRM import/filter status' },
  { env: 'AMOCRM_CREATE_PIPELINE_ID', key: 'createPipelineId', purpose: 'Pipeline for leads created by /api/bookings' },
  { env: 'AMOCRM_CREATE_STATUS_ID', key: 'createStatusId', purpose: 'Status for leads created by /api/bookings' },
  { env: 'AMOCRM_SENT_STATUS_ID', key: 'sentStatusId', purpose: 'Status after IDENT accepts ticket' },
  { env: 'AMOCRM_FAILED_STATUS_ID', key: 'failedStatusId', purpose: 'Status when ticket cannot be exported to IDENT' }
];

const TIMETABLE_FIELD_BINDINGS = [
  { env: 'AMOCRM_SLOT_FIELD_START_ID', key: 'start', purpose: 'Slot start date/time' },
  { env: 'AMOCRM_SLOT_FIELD_END_ID', key: 'end', purpose: 'Slot end date/time' },
  { env: 'AMOCRM_SLOT_FIELD_DOCTOR_ID_ID', key: 'doctorId', purpose: 'IDENT doctor ID' },
  { env: 'AMOCRM_SLOT_FIELD_DOCTOR_NAME_ID', key: 'doctorName', purpose: 'IDENT doctor name' },
  { env: 'AMOCRM_SLOT_FIELD_BRANCH_ID_ID', key: 'branchId', purpose: 'IDENT branch ID' },
  { env: 'AMOCRM_SLOT_FIELD_BRANCH_NAME_ID', key: 'branchName', purpose: 'IDENT branch name' },
  { env: 'AMOCRM_SLOT_FIELD_IS_BUSY_ID', key: 'isBusy', purpose: 'Slot busy/free flag' },
  { env: 'AMOCRM_SLOT_FIELD_IDENT_KEY_ID', key: 'identKey', purpose: 'Stable IDENT slot key' }
];

export async function buildAmoSchemaReport({ config, amoClient }) {
  const [leadFieldsRaw, pipelinesRaw, catalogsRaw] = await Promise.all([
    amoClient.listLeadCustomFields(),
    amoClient.listPipelines(),
    amoClient.listCatalogs()
  ]);

  const leadFields = leadFieldsRaw.map(summarizeField);
  const pipelines = pipelinesRaw.map(summarizePipeline);
  const catalogs = catalogsRaw.map(summarizeCatalog);
  const timetableCatalog = bindCatalog(config.amo.timetableCatalogId, catalogs, config.amo.syncTimetableToCatalog);
  const shouldLoadCatalogFields = Boolean(config.amo.timetableCatalogId && timetableCatalog.status === 'matched');
  const timetableFields = shouldLoadCatalogFields
    ? (await amoClient.listCatalogCustomFields(config.amo.timetableCatalogId)).map(summarizeField)
    : [];

  const bindings = {
    leadFields: LEAD_FIELD_BINDINGS.map((spec) =>
      bindField(spec, config.amo.fields[spec.key], leadFields, {
        required: spec.key === 'planStart' && ['api', 'both'].includes(config.amo.getTicketsSource)
      })
    ),
    pipelineStatuses: PIPELINE_BINDINGS.map((spec) => bindPipelineStatus(spec, config.amo[spec.key], pipelines)),
    timetableCatalog,
    timetableFields: TIMETABLE_FIELD_BINDINGS.map((spec) =>
      bindField(spec, config.amo.timetableFields[spec.key], timetableFields, {
        required: config.amo.syncTimetableToCatalog && spec.key === 'identKey'
      })
    )
  };

  const issues = collectIssues(bindings, config);

  return {
    generatedAt: new Date().toISOString(),
    baseUrl: config.amo.baseUrl || null,
    issues,
    leadFields,
    pipelines,
    catalogs,
    bindings
  };
}

function summarizeField(field) {
  return {
    id: field.id,
    name: field.name || null,
    type: field.type || null,
    code: field.code || null,
    sort: field.sort ?? null,
    isRequired: Boolean(field.is_required),
    isApiOnly: Boolean(field.is_api_only),
    enums: Array.isArray(field.enums)
      ? field.enums.map((item) => ({ id: item.id, value: item.value || null }))
      : []
  };
}

function summarizePipeline(pipeline) {
  return {
    id: pipeline.id,
    name: pipeline.name || null,
    sort: pipeline.sort ?? null,
    isMain: Boolean(pipeline.is_main),
    statuses: (pipeline._embedded?.statuses || []).map((status) => ({
      id: status.id,
      name: status.name || null,
      sort: status.sort ?? null,
      pipelineId: status.pipeline_id || pipeline.id,
      type: status.type ?? null
    }))
  };
}

function summarizeCatalog(catalog) {
  return {
    id: catalog.id,
    name: catalog.name || null,
    type: catalog.type || null,
    sort: catalog.sort ?? null,
    canAddElements: Boolean(catalog.can_add_elements)
  };
}

function bindField(spec, configuredId, fields, options = {}) {
  const field = fields.find((item) => Number(item.id) === Number(configuredId));
  return {
    env: spec.env,
    key: spec.key,
    purpose: spec.purpose,
    importance: options.required ? 'required' : spec.importance || 'optional',
    configuredId: configuredId || null,
    status: bindingStatus(configuredId, field, options.required),
    field: field || null
  };
}

function bindPipelineStatus(spec, configuredId, pipelines) {
  const pipeline = pipelines.find((item) => Number(item.id) === Number(configuredId));
  const statusMatch = findStatus(pipelines, configuredId);
  return {
    env: spec.env,
    key: spec.key,
    purpose: spec.purpose,
    configuredId: configuredId || null,
    status: bindingStatus(configuredId, pipeline || statusMatch?.status, false),
    pipeline: pipeline || statusMatch?.pipeline || null,
    pipelineStatus: statusMatch?.status || null
  };
}

function bindCatalog(configuredId, catalogs, required) {
  const catalog = catalogs.find((item) => Number(item.id) === Number(configuredId));
  return {
    env: 'AMOCRM_TIMETABLE_CATALOG_ID',
    purpose: 'amoCRM catalog for IDENT timetable slots',
    configuredId: configuredId || null,
    status: bindingStatus(configuredId, catalog, required),
    catalog: catalog || null
  };
}

function findStatus(pipelines, configuredId) {
  if (!configuredId) return null;
  for (const pipeline of pipelines) {
    const status = pipeline.statuses.find((item) => Number(item.id) === Number(configuredId));
    if (status) return { pipeline, status };
  }
  return null;
}

function bindingStatus(configuredId, entity, required) {
  if (!configuredId) return required ? 'missing' : 'not_configured';
  return entity ? 'matched' : 'not_found';
}

function collectIssues(bindings, config) {
  const issues = [];
  for (const binding of bindings.leadFields) {
    addBindingIssue(issues, binding, 'lead_field');
  }
  for (const binding of bindings.pipelineStatuses) {
    addBindingIssue(issues, binding, 'pipeline_status');
  }
  if (config.amo.syncTimetableToCatalog) {
    addBindingIssue(issues, bindings.timetableCatalog, 'timetable_catalog');
    for (const binding of bindings.timetableFields) addBindingIssue(issues, binding, 'timetable_field');
  }
  return issues;
}

function addBindingIssue(issues, binding, type) {
  if (binding.status === 'matched' || binding.status === 'not_configured') return;
  issues.push({
    type,
    env: binding.env,
    status: binding.status,
    message:
      binding.status === 'missing'
        ? `${binding.env} is required but not configured`
        : `${binding.env}=${binding.configuredId} was not found in amoCRM schema`
  });
}
