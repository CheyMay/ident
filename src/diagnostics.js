export async function buildDiagnostics({
  config,
  storage,
  tokenStore,
  ticketQueue,
  jobQueue,
  mappingStore,
  amoClient
}) {
  const [token, timetable, tickets, jobs, mappings, webhooks] = await Promise.all([
    tokenStore.get(),
    storage.readJson('timetable.json', null),
    ticketQueue.summary(),
    jobQueue.summary(),
    mappingStore.get(),
    storage.readJson('amocrm-webhooks.json', { events: [] })
  ]);

  const issues = [];
  const amoTokenPresent = Boolean(token.accessToken);
  const timetableAgeMs = timetable?.receivedAt ? Date.now() - new Date(timetable.receivedAt).getTime() : null;
  const webhookEvents = Array.isArray(webhooks.events) ? webhooks.events : [];

  addIssue(issues, !config.identIntegrationKey, 'error', 'ident_key_missing', 'IDENT_INTEGRATION_KEY is not configured');
  addIssue(issues, !config.serviceApiKey, 'warn', 'service_api_key_missing', 'SERVICE_API_KEY is not configured; internal API endpoints are unprotected');
  addIssue(issues, !timetable, 'warn', 'ident_timetable_missing', 'IDENT timetable has not been received yet');
  addIssue(
    issues,
    timetableAgeMs !== null && timetableAgeMs > 6 * 60 * 60 * 1000,
    'warn',
    'ident_timetable_stale',
    'IDENT timetable is older than 6 hours'
  );
  addIssue(
    issues,
    config.ident.requireDoctorMapping && mappings.doctors.length === 0,
    'error',
    'doctor_mappings_missing',
    'IDENT_REQUIRE_DOCTOR_MAPPING is enabled, but no doctors are available in mappings'
  );
  addIssue(issues, tickets.statuses.failed > 0, 'error', 'tickets_failed', 'There are failed IDENT tickets');
  addIssue(issues, jobs.statuses.failed > 0, 'error', 'jobs_failed', 'There are failed integration jobs');
  addIssue(
    issues,
    Boolean(amoClient) && !amoTokenPresent,
    'error',
    'amocrm_token_missing',
    'amoCRM is configured but access token is missing'
  );
  addIssue(
    issues,
    config.amo.syncTimetableToCatalog && !config.amo.timetableCatalogId,
    'error',
    'amocrm_catalog_missing',
    'AMOCRM_SYNC_TIMETABLE_TO_CATALOG is enabled, but AMOCRM_TIMETABLE_CATALOG_ID is empty'
  );
  addIssue(
    issues,
    Boolean(amoClient) && !config.publicBaseUrl,
    'warn',
    'public_base_url_missing',
    'PUBLIC_BASE_URL is not configured; amoCRM webhook setup cannot build callback URL'
  );
  addIssue(
    issues,
    ['api', 'both'].includes(config.amo.getTicketsSource) && !config.amo.fields.planStart,
    'warn',
    'amocrm_plan_start_field_missing',
    'AMOCRM_FIELD_PLAN_START_ID is not configured; imported leads will not carry planned appointment time'
  );

  const status = issues.some((issue) => issue.severity === 'error')
    ? 'error'
    : issues.some((issue) => issue.severity === 'warn')
      ? 'warn'
      : 'ok';

  return {
    status,
    ready: status !== 'error',
    generatedAt: new Date().toISOString(),
    issues,
    config: {
      publicBaseUrlConfigured: Boolean(config.publicBaseUrl),
      serviceApiKeyConfigured: Boolean(config.serviceApiKey),
      corsAllowedOrigins: config.cors.allowedOrigins,
      dedupeEnabled: config.dedupe.enabled,
      dedupeWindowMinutes: config.dedupe.windowMinutes,
      storageDriver: config.storage.driver,
      jobWorkerEnabled: config.jobs.workerEnabled,
      jobWorkerIntervalMs: config.jobs.workerIntervalMs
    },
    ident: {
      integrationKeyConfigured: Boolean(config.identIntegrationKey),
      requireDoctorMapping: config.ident.requireDoctorMapping,
      timetable: timetable
        ? {
            receivedAt: timetable.receivedAt,
            ageSeconds: timetableAgeMs === null ? null : Math.max(0, Math.round(timetableAgeMs / 1000)),
            summary: timetable.Summary || {
              doctors: timetable.Doctors?.length || 0,
              branches: timetable.Branches?.length || 0,
              intervals: timetable.Intervals?.length || 0
            }
          }
        : null,
      mappings: {
        updatedAt: mappings.updatedAt,
        doctors: mappings.doctors.length,
        branches: mappings.branches.length
      }
    },
    amoCRM: {
      clientConfigured: Boolean(amoClient),
      oauthConfigured: Boolean(config.amo.clientId && config.amo.clientSecret && config.amo.redirectUri),
      tokenPresent: amoTokenPresent,
      tokenExpiresAt: token.expiresAt || null,
      baseUrl: token.baseUrl || config.amo.baseUrl || null,
      getTicketsSource: config.amo.getTicketsSource,
      rateLimit: config.amo.rateLimit,
      webhookDestination: config.publicBaseUrl ? `${config.publicBaseUrl}/webhooks/amocrm` : null,
      webhookEvents: config.amo.webhookEvents,
      syncTimetableToCatalog: config.amo.syncTimetableToCatalog,
      timetableCatalogId: config.amo.timetableCatalogId,
      fields: {
        planStart: Boolean(config.amo.fields.planStart),
        planEnd: Boolean(config.amo.fields.planEnd),
        doctorId: Boolean(config.amo.fields.doctorId),
        doctorAmoId: Boolean(config.amo.fields.doctorAmoId),
        doctorName: Boolean(config.amo.fields.doctorName),
        comment: Boolean(config.amo.fields.comment),
        formName: Boolean(config.amo.fields.formName)
      }
    },
    tickets,
    jobs,
    webhooks: {
      totalStored: webhookEvents.length,
      lastReceivedAt: webhookEvents[0]?.receivedAt || null,
      lastLeadIds: webhookEvents[0]?.leadIds || []
    }
  };
}

function addIssue(issues, condition, severity, code, message) {
  if (!condition) return;
  issues.push({ severity, code, message });
}
