import path from 'node:path';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function loadConfig(env = loadEnv()) {
  const dataDir = path.resolve(rootDir, env.DATA_DIR || './data');
  const tokenFile = path.resolve(rootDir, env.AMOCRM_TOKEN_FILE || path.join(dataDir, 'amocrm-token.json'));
  const sqliteFile = path.resolve(rootDir, env.SQLITE_FILE || path.join(dataDir, 'integration.sqlite'));

  return {
    rootDir,
    port: intFromEnv(env.PORT, 8080),
    publicBaseUrl: trimSlash(env.PUBLIC_BASE_URL || ''),
    dataDir,
    storage: {
      driver: pickOne(env.STORAGE_DRIVER, ['json', 'sqlite'], 'json'),
      sqliteFile,
      migrateJson: parseBool(env.SQLITE_MIGRATE_JSON, true)
    },
    jobs: {
      workerEnabled: parseBool(env.JOB_WORKER_ENABLED, true),
      workerIntervalMs: intFromEnv(env.JOB_WORKER_INTERVAL_MS, 30_000),
      batchSize: intFromEnv(env.JOB_BATCH_SIZE, 10),
      maxAttempts: intFromEnv(env.JOB_MAX_ATTEMPTS, 8),
      retryBaseDelayMs: intFromEnv(env.JOB_RETRY_BASE_DELAY_MS, 60_000)
    },
    ident: {
      requireDoctorMapping: parseBool(env.IDENT_REQUIRE_DOCTOR_MAPPING, false)
    },
    identIntegrationKey: env.IDENT_INTEGRATION_KEY || '',
    serviceApiKey: env.SERVICE_API_KEY || '',
    amo: {
      baseUrl: normalizeAmoBaseUrl(env),
      clientId: env.AMOCRM_CLIENT_ID || '',
      clientSecret: env.AMOCRM_CLIENT_SECRET || '',
      redirectUri: env.AMOCRM_REDIRECT_URI || '',
      accessToken: env.AMOCRM_ACCESS_TOKEN || '',
      refreshToken: env.AMOCRM_REFRESH_TOKEN || '',
      longLivedToken: parseBool(env.AMOCRM_LONG_LIVED_TOKEN, false),
      tokenFile,
      pipelineId: optionalInt(env.AMOCRM_PIPELINE_ID),
      statusId: optionalInt(env.AMOCRM_STATUS_ID),
      ticketDateSource: env.AMOCRM_TICKET_DATE_SOURCE === 'created_at' ? 'created_at' : 'updated_at',
      getTicketsSource: pickOne(env.AMOCRM_GETTICKETS_SOURCE, ['queue', 'api', 'both'], 'both'),
      defaultAppointmentMinutes: intFromEnv(env.AMOCRM_DEFAULT_APPOINTMENT_MINUTES, 60),
      createPipelineId: optionalInt(env.AMOCRM_CREATE_PIPELINE_ID),
      createStatusId: optionalInt(env.AMOCRM_CREATE_STATUS_ID),
      sentStatusId: optionalInt(env.AMOCRM_SENT_STATUS_ID),
      failedStatusId: optionalInt(env.AMOCRM_FAILED_STATUS_ID),
      createTag: env.AMOCRM_CREATE_TAG || 'IDENT',
      addNotes: parseBool(env.AMOCRM_ADD_NOTES, true),
      webhookEvents: listFromEnv(env.AMOCRM_WEBHOOK_EVENTS, ['add_lead', 'update_lead', 'status_lead']),
      syncTimetableToCatalog: parseBool(env.AMOCRM_SYNC_TIMETABLE_TO_CATALOG, false),
      timetableCatalogId: optionalInt(env.AMOCRM_TIMETABLE_CATALOG_ID),
      timetableSyncFreeOnly: parseBool(env.AMOCRM_TIMETABLE_SYNC_FREE_ONLY, true),
      timetableMaxSync: intFromEnv(env.AMOCRM_TIMETABLE_MAX_SYNC, 100),
      timetableFields: {
        start: optionalInt(env.AMOCRM_SLOT_FIELD_START_ID),
        end: optionalInt(env.AMOCRM_SLOT_FIELD_END_ID),
        doctorId: optionalInt(env.AMOCRM_SLOT_FIELD_DOCTOR_ID_ID),
        doctorName: optionalInt(env.AMOCRM_SLOT_FIELD_DOCTOR_NAME_ID),
        branchId: optionalInt(env.AMOCRM_SLOT_FIELD_BRANCH_ID_ID),
        branchName: optionalInt(env.AMOCRM_SLOT_FIELD_BRANCH_NAME_ID),
        isBusy: optionalInt(env.AMOCRM_SLOT_FIELD_IS_BUSY_ID),
        identKey: optionalInt(env.AMOCRM_SLOT_FIELD_IDENT_KEY_ID)
      },
      fields: {
        planStart: optionalInt(env.AMOCRM_FIELD_PLAN_START_ID),
        planEnd: optionalInt(env.AMOCRM_FIELD_PLAN_END_ID),
        doctorId: optionalInt(env.AMOCRM_FIELD_DOCTOR_ID_ID),
        doctorName: optionalInt(env.AMOCRM_FIELD_DOCTOR_NAME_ID),
        doctorAmoId: optionalInt(env.AMOCRM_FIELD_DOCTOR_AMO_ID_ID),
        comment: optionalInt(env.AMOCRM_FIELD_COMMENT_ID),
        formName: optionalInt(env.AMOCRM_FIELD_FORM_NAME_ID),
        utmSource: optionalInt(env.AMOCRM_FIELD_UTM_SOURCE_ID),
        utmMedium: optionalInt(env.AMOCRM_FIELD_UTM_MEDIUM_ID),
        utmCampaign: optionalInt(env.AMOCRM_FIELD_UTM_CAMPAIGN_ID),
        utmTerm: optionalInt(env.AMOCRM_FIELD_UTM_TERM_ID),
        utmContent: optionalInt(env.AMOCRM_FIELD_UTM_CONTENT_ID),
        httpReferer: optionalInt(env.AMOCRM_FIELD_HTTP_REFERER_ID)
      }
    }
  };
}

export function loadEnv(filePath = path.join(rootDir, '.env'), baseEnv = process.env) {
  if (!existsSync(filePath)) return baseEnv;

  const fileEnv = {};
  for (const line of readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const separator = trimmed.indexOf('=');
    if (separator === -1) continue;
    const key = trimmed.slice(0, separator).trim();
    const value = unquote(trimmed.slice(separator + 1).trim());
    if (key) fileEnv[key] = value;
  }
  return { ...fileEnv, ...baseEnv };
}

export function isAmoConfigured(config) {
  return Boolean(config.amo.accessToken || (config.amo.clientId && config.amo.clientSecret));
}

function normalizeAmoBaseUrl(env) {
  const explicit = trimSlash(env.AMOCRM_BASE_URL || '');
  if (explicit) return explicit;
  const subdomain = (env.AMOCRM_SUBDOMAIN || '').trim();
  return subdomain ? `https://${subdomain}.amocrm.ru` : '';
}

function trimSlash(value) {
  return String(value).trim().replace(/\/+$/, '');
}

function optionalInt(value) {
  if (value === undefined || value === null || String(value).trim() === '') return null;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function intFromEnv(value, fallback) {
  const parsed = optionalInt(value);
  return parsed ?? fallback;
}

function parseBool(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
}

function listFromEnv(value, fallback) {
  if (value === undefined || value === null || String(value).trim() === '') return fallback;
  return String(value)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function pickOne(value, allowed, fallback) {
  const normalized = String(value || '').trim();
  return allowed.includes(normalized) ? normalized : fallback;
}

function unquote(value) {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }
  return value;
}
