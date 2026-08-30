import { createServer } from 'node:http';
import { URL } from 'node:url';
import { AgentReleaseStore } from './agent-releases.js';
import { bootstrapAmoDefaults } from './amocrm/bootstrap.js';
import { AmoClient } from './amocrm/client.js';
import {
  buildAmoAuthorizeUrl,
  getAmoOAuthStatus,
  OAuthStateStore,
  verifyDisconnectSignature
} from './amocrm/oauth.js';
import { buildAmoSchemaReport } from './amocrm/schema.js';
import { AmoTokenStore } from './amocrm/token-store.js';
import { syncTimetableToAmoCatalog } from './amocrm/timetable-sync.js';
import { extractLeadIdsFromWebhook, parseWebhookBody } from './amocrm/webhooks.js';
import { isAmoConfigured } from './config.js';
import { parseDateParam } from './date.js';
import { buildDiagnostics } from './diagnostics.js';
import {
  applyDoctorMapping,
  MappingStore
} from './ident/mapping-store.js';
import { normalizeAndValidateIdentTicket, normalizeAndValidateTicket } from './ident/ticket-validation.js';
import {
  BadRequestError,
  filterTickets,
  normalizeBookingTicket,
  normalizeTimeTablePayload,
  validateIdentKey
} from './ident/contracts.js';
import {
  createIdentDbClient,
  defaultIdentDbMapping,
  normalizeIdentDbMapping,
  validateReadOnlySql
} from './ident/db-client.js';
import { bookingToAmoLead, leadToIdentTicket } from './ident/mappers.js';
import { buildEffectiveConfig, SettingsStore } from './settings.js';
import {
  AgentDiagnosticsStore,
  AgentSchemaStore,
  AgentStatusStore,
  AmoSlotStore,
  createStorage,
  IntegrationJobQueue,
  TicketQueue,
  WebhookLog
} from './storage.js';

export function buildApp(config, logger, options = {}) {
  const baseConfig = structuredClone(config);
  const storage = createStorage(config, logger);
  const ticketQueue = new TicketQueue(storage, {
    timetableMaxAgeMinutes: config.ident.timetableMaxAgeMinutes,
    reservationMinutes: config.ident.reservationMinutes,
    robotFailureHoldMinutes: config.ident.robotFailureHoldMinutes
  });
  const jobQueue = new IntegrationJobQueue(storage);
  const mappingStore = new MappingStore(storage);
  const slotStore = new AmoSlotStore(storage);
  const webhookLog = new WebhookLog(storage);
  const agentStore = new AgentStatusStore(storage, config.agent.offlineAfterSeconds);
  const agentDiagnosticsStore = new AgentDiagnosticsStore(storage);
  const agentSchemaStore = new AgentSchemaStore(storage);
  const agentReleaseStore = new AgentReleaseStore(storage, {
    directory: config.agent.releaseDirectory,
    maxArchiveBytes: config.agent.releaseMaxBytes
  });
  const settingsStore = new SettingsStore(storage);
  const oauthStateStore = new OAuthStateStore(storage);
  const identDbClient = options.identDbClient || createIdentDbClient(config, logger);
  const tokenStore = new AmoTokenStore(
    config.amo.tokenFile,
    {
      accessToken: config.amo.accessToken,
      refreshToken: config.amo.refreshToken,
      expiresAt: 0,
      baseUrl: config.amo.baseUrl
    },
    config.storage.driver === 'sqlite' ? { storage, storageKey: 'amocrm-token.json' } : {}
  );
  const amoClient = isAmoConfigured(config) ? new AmoClient(config, tokenStore, logger) : null;
  let workerTimer = null;
  let workerRunning = false;

  if (config.jobs.workerEnabled) {
    workerTimer = setInterval(() => {
      if (workerRunning) return;
      workerRunning = true;
      processDueJobs({ jobQueue, ticketQueue, mappingStore, storage, slotStore, amoClient, config, logger })
        .catch((error) => logger.error('Job worker failed', { message: error.message }))
        .finally(() => {
          workerRunning = false;
        });
    }, config.jobs.workerIntervalMs);
    workerTimer.unref?.();
  }

  async function storeTimetable(body) {
    const timetable = normalizeTimeTablePayload(body);
    await storage.writeJson('timetable.json', timetable);
    await ticketQueue.reconcileReservations(timetable);
    await mappingStore.syncFromTimetable(timetable);
    logger.info('IDENT timetable received', timetable.Summary);

    if (config.amo.syncTimetableToCatalog) {
      await jobQueue.enqueue('amocrm.timetable_sync', {}, {
        dedupeKey: 'amocrm.timetable_sync',
        maxAttempts: config.jobs.maxAttempts
      });
    }

    return timetable;
  }

  async function handle(req, res) {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    if (applyCors(req, res, config)) return;

    try {
      await applyRuntimeSettings();
      if (req.method === 'GET' && url.pathname === '/health') {
        const token = await tokenStore.get();
        return sendJson(res, 200, {
          ok: true,
          amoConfigured: Boolean(amoClient && token.accessToken),
          amoOAuthConfigured: Boolean(config.amo.clientId && config.amo.clientSecret && config.amo.redirectUri),
          identKeyConfigured: Boolean(config.identIntegrationKey),
          storageDriver: config.storage.driver
        });
      }

      if (req.method === 'POST' && url.pathname === '/PostTimeTable') {
        const auth = validateIdentKey(req, config);
        if (!auth.ok) return sendText(res, auth.status, auth.message);

        await storeTimetable(await readJson(req));
        return sendText(res, 200, 'OK');
      }

      if (req.method === 'GET' && url.pathname === '/GetTickets') {
        const auth = validateIdentKey(req, config);
        if (!auth.ok) return sendText(res, auth.status, auth.message);

        await ticketQueue.releaseExpiredRobotClaims();
        if (await agentStore.hasRobotModeEnabled()) {
          return sendJson(res, 200, []);
        }
        const range = parseIdentRange(url);
        const tickets = await loadTicketsForIdent({ ticketQueue, mappingStore, jobQueue, amoClient, tokenStore, config, range, logger });
        const sentRecords = await ticketQueue.markSent(tickets.map((ticket) => ticket.Id));
        if (sentRecords.length && amoClient) {
          await enqueueAmoTicketsSent({ records: sentRecords, jobQueue, config });
        }
        return sendJson(res, 200, tickets);
      }

      if (req.method === 'GET' && url.pathname === '/api/timetable') {
        requireServiceApiKey(req, config);
        const timetable = await storage.readJson('timetable.json', null);
        if (!timetable) return sendJson(res, 404, { error: 'Timetable has not been received yet' });
        return sendJson(res, 200, await ticketQueue.timetableWithReservations(timetable));
      }

      if (req.method === 'GET' && url.pathname === '/api/free-slots') {
        requireServiceApiKey(req, config);
        const timetable = await storage.readJson('timetable.json', null);
        if (!timetable) return sendJson(res, 404, { error: 'Timetable has not been received yet' });
        const availableTimetable = await ticketQueue.timetableWithReservations(timetable);
        return sendJson(res, 200, {
          receivedAt: availableTimetable.receivedAt,
          Doctors: availableTimetable.Doctors,
          Branches: availableTimetable.Branches,
          Intervals: availableTimetable.Intervals.filter((item) => !item.IsBusy)
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/services') {
        requireServiceApiKey(req, config);
        const timetable = await storage.readJson('timetable.json', null);
        if (!timetable) return sendJson(res, 404, { error: 'Timetable has not been received yet' });
        const services = Array.isArray(timetable.Services) ? timetable.Services : [];
        return sendJson(res, 200, {
          receivedAt: timetable.receivedAt,
          Services: services,
          Summary: {
            services: services.length,
            priceGroups: new Set(services.map((item) => item.PriceGroupId).filter(Boolean)).size,
            folders: new Set(services.map((item) => item.FolderId).filter(Boolean)).size
          }
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/diagnostics') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await buildDiagnostics({
          config,
          storage,
          tokenStore,
          ticketQueue,
          jobQueue,
          mappingStore,
          identDbClient,
          amoClient,
          agentStore
        }));
      }

      if (req.method === 'POST' && url.pathname === '/api/agent/heartbeat') {
        requireAgentApiKey(req, config);
        return sendJson(res, 200, await agentStore.heartbeat(await readJson(req)));
      }

      if (req.method === 'POST' && url.pathname === '/api/agent/timetable') {
        requireAgentApiKey(req, config);
        const timetable = await storeTimetable(await readJson(req));
        return sendJson(res, 200, {
          ok: true,
          receivedAt: timetable.receivedAt,
          summary: timetable.Summary
        });
      }

      if (req.method === 'POST' && url.pathname === '/api/agent/schema') {
        requireAgentApiKey(req, config);
        const body = await readJson(req);
        if (!body.agentId || !body.schema) {
          return sendJson(res, 400, { error: 'agentId and schema are required' });
        }
        const record = await agentSchemaStore.put(body.agentId, body.schema);
        return sendJson(res, 200, {
          ok: true,
          agentId: record.agentId,
          receivedAt: record.receivedAt,
          summary: record.summary
        });
      }

      if (req.method === 'POST' && url.pathname === '/api/agent/diagnostics') {
        requireAgentApiKey(req, config);
        const body = await readJson(req, 512 * 1024);
        if (!body.agentId || !body.report) {
          return sendJson(res, 400, { error: 'agentId and report are required' });
        }
        return sendJson(res, 200, {
          report: await agentDiagnosticsStore.put(body.agentId, body.report)
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/agent/diagnostics') {
        requireServiceApiKey(req, config);
        const agentId = url.searchParams.get('agentId');
        if (!agentId) return sendJson(res, 400, { error: 'agentId is required' });
        const report = await agentDiagnosticsStore.get(agentId);
        if (!report) return sendJson(res, 404, { error: 'Agent diagnostics have not been received yet' });
        return sendJson(res, 200, report);
      }

      if (req.method === 'GET' && url.pathname === '/api/agent/schema') {
        requireServiceApiKey(req, config);
        const agentId = url.searchParams.get('agentId');
        if (!agentId) return sendJson(res, 400, { error: 'agentId is required' });
        const record = await agentSchemaStore.get(agentId);
        if (!record) return sendJson(res, 404, { error: 'Agent schema has not been received yet' });
        return sendJson(res, 200, record);
      }

      if (req.method === 'GET' && url.pathname === '/api/agent/config') {
        requireAgentApiKey(req, config);
        const agentId = url.searchParams.get('agentId');
        if (!agentId) return sendJson(res, 400, { error: 'agentId is required' });
        return sendJson(res, 200, { desired: await agentStore.desiredFor(agentId) });
      }

      if (req.method === 'POST' && url.pathname === '/api/agent/config') {
        requireAgentApiKey(req, config);
        const body = normalizeAgentDesiredInput(await readJson(req));
        if (!body.agentId) return sendJson(res, 400, { error: 'agentId is required' });
        if (body.robotEnabled === true && !(await agentStore.isRobotConfigured(body.agentId))) {
          return sendJson(res, 409, { error: 'Robot must be calibrated and online before it can be enabled' });
        }
        if (body.robotEnabled === true) {
          const currentDesired = await agentStore.desiredFor(body.agentId);
          if (currentDesired.robotEnabled !== true) {
            body.robotActivationCutoff = new Date().toISOString();
          }
        }
        return sendJson(res, 200, {
          agentId: String(body.agentId),
          desired: await agentStore.setDesired(body.agentId, body)
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/agent/status') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await agentStore.status());
      }

      if (req.method === 'GET' && url.pathname === '/api/agent/releases') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, { releases: await agentReleaseStore.list() });
      }

      if (req.method === 'POST' && url.pathname === '/api/agent/releases') {
        requireServiceApiKey(req, config);
        const body = await readJson(req, Math.ceil(config.agent.releaseMaxBytes * 1.4) + 128 * 1024);
        return sendJson(res, 201, { release: await agentReleaseStore.publish(body) });
      }

      const releaseDownloadMatch = url.pathname.match(/^\/api\/agent\/releases\/([^/]+)\/download$/);
      if (req.method === 'GET' && releaseDownloadMatch) {
        requireAgentApiKey(req, config);
        const stored = await agentReleaseStore.readArchive(decodeURIComponent(releaseDownloadMatch[1]));
        if (!stored) return sendJson(res, 404, { error: 'Agent release not found' });
        return sendBuffer(res, 200, stored.archive, {
          'Content-Type': 'application/zip',
          'Content-Disposition': `attachment; filename="ident-desktop-${stored.release.version}.zip"`,
          'X-Content-Type-Options': 'nosniff',
          'X-Agent-Release-Version': stored.release.version,
          'X-Agent-Release-SHA256': stored.release.sha256
        });
      }

      if (req.method === 'POST' && url.pathname === '/api/agent/settings') {
        requireServiceApiKey(req, config);
        const body = normalizeAgentDesiredInput(await readJson(req));
        if (!body.agentId) return sendJson(res, 400, { error: 'agentId is required' });
        if (Object.prototype.hasOwnProperty.call(body, 'targetVersion')) {
          const targetVersion = String(body.targetVersion || '').trim();
          if (!targetVersion) {
            body.update = null;
          } else {
            const release = await agentReleaseStore.get(targetVersion);
            if (!release) return sendJson(res, 404, { error: 'Agent release not found' });
            body.update = release;
          }
        }
        if (body.robotEnabled === true && !(await agentStore.isRobotConfigured(body.agentId))) {
          return sendJson(res, 409, { error: 'Robot must be calibrated and online before it can be enabled' });
        }
        return sendJson(res, 200, {
          agentId: String(body.agentId),
          desired: await agentStore.setDesired(body.agentId, body)
        });
      }

      if (req.method === 'POST' && url.pathname === '/api/robot/tasks/claim') {
        requireAgentApiKey(req, config);
        const body = await readJson(req);
        if (!body.agentId) return sendJson(res, 400, { error: 'agentId is required' });
        if (!(await agentStore.isRobotModeEnabled(body.agentId))) {
          return sendJson(res, 409, { error: 'Robot mode is not enabled for this agent' });
        }
        const timetable = await storage.readJson('timetable.json', null);
        const desired = await agentStore.desiredFor(body.agentId);
        const record = await ticketQueue.claimForRobot(
          body.agentId,
          config.agent.robotLeaseSeconds,
          timetable,
          desired.robotActivationCutoff
        );
        return sendJson(res, 200, { record });
      }

      if (req.method === 'POST' && url.pathname === '/api/robot/tasks/complete') {
        requireAgentApiKey(req, config);
        const body = await readJson(req);
        if (!body.id || !body.agentId) return sendJson(res, 400, { error: 'id and agentId are required' });
        const record = await ticketQueue.completeRobot(body.id, body.agentId, body.result);
        if (!record) return sendJson(res, 409, { error: 'Robot task is not claimed by this agent' });
        return sendJson(res, 200, { record });
      }

      if (req.method === 'POST' && url.pathname === '/api/robot/tasks/defer') {
        requireAgentApiKey(req, config);
        const body = await readJson(req);
        if (!body.id || !body.agentId) return sendJson(res, 400, { error: 'id and agentId are required' });
        const record = await ticketQueue.deferRobot(body.id, body.agentId, body.reason);
        if (!record) return sendJson(res, 409, { error: 'Robot task is not owned by this agent' });
        return sendJson(res, 200, { record });
      }

      if (req.method === 'POST' && url.pathname === '/api/robot/tasks/fail') {
        requireAgentApiKey(req, config);
        const body = await readJson(req);
        if (!body.id || !body.agentId) return sendJson(res, 400, { error: 'id and agentId are required' });
        const record = await ticketQueue.failRobot(body.id, body.agentId, body.error);
        if (!record) return sendJson(res, 409, { error: 'Robot task is not claimed by this agent' });
        return sendJson(res, 200, { record });
      }

      if (req.method === 'GET' && url.pathname === '/api/ident-db/status') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await getIdentDbStatus({ identDbClient }));
      }

      if (req.method === 'GET' && url.pathname === '/api/ident-db/schema') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await identDbClient.getSchema());
      }

      if (req.method === 'GET' && url.pathname === '/api/ident-db/table') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await identDbClient.getTableRows({
          schema: url.searchParams.get('schema') || 'dbo',
          table: url.searchParams.get('table') || '',
          limit: url.searchParams.get('limit') || undefined
        }));
      }

      if (req.method === 'GET' && url.pathname === '/api/ident-db/mapping') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await getIdentDbMapping(storage));
      }

      if (req.method === 'POST' && url.pathname === '/api/ident-db/mapping') {
        requireServiceApiKey(req, config);
        const mapping = normalizeIdentDbMapping(await readJson(req));
        await storage.writeJson('ident-db-mapping.json', mapping);
        return sendJson(res, 200, mapping);
      }

      if (req.method === 'GET' && url.pathname === '/api/ident-db/preview') {
        requireServiceApiKey(req, config);
        const mapping = await getIdentDbMapping(storage);
        return sendJson(res, 200, await identDbClient.previewTimetable(mapping));
      }

      if (req.method === 'POST' && url.pathname === '/api/ident-db/sync') {
        requireServiceApiKey(req, config);
        const mapping = await getIdentDbMapping(storage);
        const preview = await identDbClient.previewTimetable(mapping);
        await storage.writeJson('timetable.json', {
          ...preview.timetable,
          source: 'ident-db',
          syncedAt: new Date().toISOString()
        });
        await ticketQueue.reconcileReservations(preview.timetable);
        await mappingStore.syncFromTimetable(preview.timetable);
        if (config.amo.syncTimetableToCatalog) {
          await jobQueue.enqueue('amocrm.timetable_sync', {}, {
            dedupeKey: 'amocrm.timetable_sync',
            maxAttempts: config.jobs.maxAttempts
          });
        }
        return sendJson(res, 200, {
          source: 'ident-db',
          syncedAt: new Date().toISOString(),
          timetable: preview.timetable
        });
      }

      if (req.method === 'POST' && url.pathname === '/api/bookings') {
        requireServiceApiKey(req, config);
        const body = await readJson(req);
        const requireAmoLead = body.requireAmoLead === true;
        const createAmoLead = body.createAmoLead !== false;
        if (requireAmoLead && !createAmoLead) {
          return sendJson(res, 400, {
            error: 'requireAmoLead and createAmoLead=false cannot be used together'
          });
        }
        if (requireAmoLead) {
          const token = await tokenStore.get();
          if (!amoClient || !token.accessToken) {
            return sendJson(res, 409, {
              error: 'amoCRM authorization is required before creating a test booking'
            });
          }
        }
        const ticket = normalizeBookingTicket(body, {
          defaultAppointmentMinutes: config.amo.defaultAppointmentMinutes
        });
        const mappingResult = await applyDoctorMapping(ticket, mappingStore, {
          requireDoctorMapping: config.ident.requireDoctorMapping
        });
        if (!mappingResult.ok) return sendJson(res, 400, { error: mappingResult.reason });
        const validation = normalizeAndValidateTicket(ticket);
        if (!validation.ok) return sendJson(res, 400, { errors: validation.errors });

        let amoLead = null;
        if (amoClient && createAmoLead) {
          amoLead = await amoClient.createLeadWithContact(bookingToAmoLead(validation.ticket, config));
          if (amoLead?.id) validation.ticket.Id = `amo:${amoLead.id}`;
        }
        if (requireAmoLead && !amoLead?.id) {
          return sendJson(res, 502, {
            error: 'amoCRM did not return a lead ID; the booking was not queued for IDENT'
          });
        }

        const timetable = await storage.readJson('timetable.json', null);
        const record = await queueTicketWithDedupe({
          ticketQueue,
          ticket: validation.ticket,
          meta: {
            source: amoLead?.id ? 'api-booking-amo' : createAmoLead ? 'api-booking' : 'amo-widget-booking',
            amoLeadId: amoLead?.id || null,
            branchId: body.branchId ?? body.BranchId ?? null
          },
          config,
          reserveSlot: true,
          timetable,
          branchId: body.branchId ?? body.BranchId ?? null
        });
        logger.info('Booking processed for IDENT', {
          id: validation.ticket.Id,
          amoLeadId: amoLead?.id || null,
          status: record.status
        });
        return sendJson(res, 201, {
          ticket: validation.ticket,
          amoLeadId: amoLead?.id || null,
          queued: record.status === 'queued',
          status: record.status,
          reservation: record.reservation || null,
          duplicateOf: record.status === 'ignored' ? record.lastError?.replace(/^Duplicate of\s+/, '') || null : null
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/tickets') {
        requireServiceApiKey(req, config);
        const status = url.searchParams.get('status') || null;
        return sendJson(res, 200, {
          records: await ticketQueue.listRecords({ status })
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/tickets/summary') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await ticketQueue.summary());
      }

      if (req.method === 'GET' && url.pathname === '/api/jobs') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, {
          jobs: await jobQueue.list({
            status: url.searchParams.get('status') || null,
            type: url.searchParams.get('type') || null
          })
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/jobs/summary') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await jobQueue.summary());
      }

      if (req.method === 'POST' && url.pathname === '/api/jobs/retry') {
        requireServiceApiKey(req, config);
        const body = await readJson(req);
        if (!body.id) return sendJson(res, 400, { error: 'id is required' });
        const job = await jobQueue.retry(String(body.id));
        if (!job) return sendJson(res, 404, { error: 'Job not found' });
        return sendJson(res, 200, { job });
      }

      if (req.method === 'POST' && url.pathname === '/api/jobs/run-due') {
        requireServiceApiKey(req, config);
        const result = await processDueJobs({ jobQueue, ticketQueue, mappingStore, storage, slotStore, amoClient, config, logger });
        return sendJson(res, 200, result);
      }

      if (req.method === 'GET' && url.pathname === '/api/mappings') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await mappingStore.get());
      }

      if (req.method === 'POST' && url.pathname === '/api/mappings') {
        requireServiceApiKey(req, config);
        const body = await readJson(req);
        return sendJson(res, 200, await mappingStore.merge(body));
      }

      if (req.method === 'GET' && url.pathname === '/api/settings/amocrm') {
        requireServiceApiKey(req, config);
        const settings = await settingsStore.get();
        return sendJson(res, 200, {
          settings,
          effective: summarizeEffectiveSettings(config)
        });
      }

      if (req.method === 'POST' && url.pathname === '/api/settings/amocrm') {
        requireServiceApiKey(req, config);
        const settings = await settingsStore.merge(await readJson(req));
        await applyRuntimeSettings(settings);
        return sendJson(res, 200, {
          settings,
          effective: summarizeEffectiveSettings(config)
        });
      }

      if (req.method === 'POST' && url.pathname === '/api/tickets/requeue') {
        requireServiceApiKey(req, config);
        const body = await readJson(req);
        if (!body.id) return sendJson(res, 400, { error: 'id is required' });
        const record = await ticketQueue.requeue(String(body.id));
        if (!record) return sendJson(res, 404, { error: 'Ticket not found' });
        return sendJson(res, 200, { record });
      }

      if (req.method === 'POST' && url.pathname === '/api/tickets/cancel') {
        requireServiceApiKey(req, config);
        const body = await readJson(req);
        if (!body.id) return sendJson(res, 400, { error: 'id is required' });
        const record = await ticketQueue.cancel(String(body.id), body.reason);
        if (!record) return sendJson(res, 404, { error: 'Ticket not found' });
        if (!record.canceled) {
          return sendJson(res, 409, { error: `Ticket with status ${record.status} cannot be canceled` });
        }
        return sendJson(res, 200, { record });
      }

      if (req.method === 'GET' && url.pathname === '/oauth/amocrm/url') {
        requireServiceApiKey(req, config);
        const oauthStatus = getAmoOAuthStatus(config);
        if (!oauthStatus.configured || !amoClient) {
          return sendJson(res, 409, {
            error: formatAmoOAuthConfigError(oauthStatus),
            code: 'AMOCRM_OAUTH_CONFIG_INCOMPLETE',
            ...oauthStatus
          });
        }
        const state = await oauthStateStore.create();
        return sendJson(res, 200, {
          url: buildAmoAuthorizeUrl(config, state, url.searchParams.get('mode') || 'popup'),
          state,
          redirectUri: config.amo.redirectUri
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/amocrm/oauth/status') {
        requireServiceApiKey(req, config);
        const token = await tokenStore.get();
        return sendJson(res, 200, {
          ...getAmoOAuthStatus(config),
          authorized: Boolean(amoClient && token.accessToken),
          tokenExpiresAt: token.expiresAt || null,
          tokenAccountUrl: token.baseUrl || null
        });
      }

      if (req.method === 'GET' && url.pathname === '/oauth/amocrm/callback') {
        if (url.searchParams.get('error')) {
          return sendHtml(res, 400, oauthHtml('amoCRM authorization rejected'));
        }
        const oauthStatus = getAmoOAuthStatus(config);
        if (!oauthStatus.configured || !amoClient) {
          logger.error('amoCRM OAuth callback rejected: server configuration is incomplete', {
            missing: oauthStatus.missing,
            referer: normalizeHost(url.searchParams.get('referer')),
            clientIdPresent: Boolean(url.searchParams.get('client_id'))
          });
          return sendHtml(res, 503, oauthHtml(formatAmoOAuthConfigError(oauthStatus)));
        }
        const state = url.searchParams.get('state');
        const stateOk = state
          ? await oauthStateStore.consume(state)
          : isTrustedAmoWidgetCallback(url, config);
        if (!stateOk) return sendHtml(res, 400, oauthHtml('Invalid OAuth state'));
        if (!url.searchParams.get('code')) return sendHtml(res, 400, oauthHtml('Authorization code is missing'));

        const token = await amoClient.exchangeAuthorizationCode({
          code: url.searchParams.get('code'),
          referer: url.searchParams.get('referer')
        });
        logger.info('amoCRM OAuth completed', { baseUrl: token.baseUrl });
        return sendHtml(res, 200, oauthHtml('amoCRM authorization completed'));
      }

      if (req.method === 'POST' && url.pathname === '/oauth/amocrm/exchange') {
        requireServiceApiKey(req, config);
        if (!amoClient) return sendJson(res, 500, { error: 'amoCRM OAuth is not configured' });
        const body = await readJson(req);
        const token = await amoClient.exchangeAuthorizationCode({
          code: body.code,
          referer: body.referer || body.baseUrl || config.amo.baseUrl
        });
        return sendJson(res, 200, {
          ok: true,
          baseUrl: token.baseUrl,
          expiresAt: token.expiresAt
        });
      }

      if (req.method === 'GET' && url.pathname === '/oauth/amocrm/disconnect') {
        if (!verifyDisconnectSignature(url.searchParams, config)) {
          return sendText(res, 403, 'Invalid signature');
        }
        await tokenStore.set({ accessToken: '', refreshToken: '', expiresAt: 0, baseUrl: config.amo.baseUrl });
        logger.warn('amoCRM integration disconnected', { accountId: url.searchParams.get('account_id') });
        return sendText(res, 200, 'OK');
      }

      if (req.method === 'POST' && url.pathname === '/webhooks/amocrm') {
        const { raw, payload } = await parseWebhookBody(req);
        const leadIds = extractLeadIdsFromWebhook(payload);
        await webhookLog.add({
          receivedAt: new Date().toISOString(),
          leadIds,
          raw
        });

        if (amoClient) {
          for (const leadId of leadIds) {
            await jobQueue.enqueue('amocrm.import_lead', { leadId }, {
              dedupeKey: `amocrm.import_lead:${leadId}`,
              maxAttempts: config.jobs.maxAttempts
            });
          }
        }

        return sendText(res, 200, 'OK');
      }

      if (req.method === 'POST' && url.pathname === '/api/amocrm/webhooks/setup') {
        requireServiceApiKey(req, config);
        if (!amoClient) return sendJson(res, 500, { error: 'amoCRM is not configured' });
        if (!config.publicBaseUrl) return sendJson(res, 500, { error: 'PUBLIC_BASE_URL is not configured' });

        const destination = `${config.publicBaseUrl}/webhooks/amocrm`;
        const webhook = await amoClient.upsertWebhook(destination, config.amo.webhookEvents);
        return sendJson(res, 200, { destination, webhook });
      }

      if (req.method === 'GET' && url.pathname === '/api/amocrm/webhooks') {
        requireServiceApiKey(req, config);
        if (!amoClient) return sendJson(res, 500, { error: 'amoCRM is not configured' });
        const destination = config.publicBaseUrl ? `${config.publicBaseUrl}/webhooks/amocrm` : '';
        return sendJson(res, 200, { webhooks: await amoClient.listWebhooks(destination || null) });
      }

      if (req.method === 'GET' && url.pathname === '/api/amocrm/schema') {
        requireServiceApiKey(req, config);
        if (!amoClient) return sendJson(res, 500, { error: 'amoCRM is not configured' });
        return sendJson(res, 200, await buildAmoSchemaReport({ config, amoClient }));
      }

      if (req.method === 'POST' && url.pathname === '/api/amocrm/bootstrap') {
        requireServiceApiKey(req, config);
        if (!amoClient) return sendJson(res, 500, { error: 'amoCRM is not configured' });
        const result = await bootstrapAmoDefaults({ config, amoClient, settingsStore });
        await applyRuntimeSettings(result.settings);
        return sendJson(res, 200, result);
      }

      if (req.method === 'GET' && url.pathname === '/api/amocrm/leads/preview') {
        requireServiceApiKey(req, config);
        if (!amoClient) return sendJson(res, 500, { error: 'amoCRM is not configured' });
        const leadId = optionalPositiveInt(url.searchParams.get('id') || url.searchParams.get('leadId'));
        if (!leadId) return sendJson(res, 400, { error: 'lead id is required' });
        return sendJson(res, 200, await buildAmoLeadPreview({ leadId, amoClient, mappingStore, config }));
      }

      if (req.method === 'POST' && url.pathname === '/api/amocrm/leads/import') {
        requireServiceApiKey(req, config);
        if (!amoClient) return sendJson(res, 500, { error: 'amoCRM is not configured' });
        const body = await readJson(req);
        const leadId = optionalPositiveInt(body.leadId ?? body.id);
        if (!leadId) return sendJson(res, 400, { error: 'leadId is required' });

        if (body.runNow === false) {
          const job = await jobQueue.enqueue('amocrm.import_lead', { leadId }, {
            dedupeKey: `amocrm.import_lead:${leadId}`,
            maxAttempts: config.jobs.maxAttempts
          });
          return sendJson(res, 202, { job });
        }

        const result = await syncAmoLeadIntoTicketQueue({
          leadId,
          amoClient,
          ticketQueue,
          mappingStore,
          jobQueue,
          config,
          logger,
          source: 'manual-import'
        });
        return sendJson(res, 200, {
          leadId,
          queued: Boolean(result.ticket),
          ticketId: result.ticket?.Id || null,
          record: result.record,
          preview: result.preview
        });
      }

      if (req.method === 'POST' && url.pathname === '/api/amocrm/timetable/sync') {
        requireServiceApiKey(req, config);
        const timetable = await storage.readJson('timetable.json', null);
        if (!timetable) return sendJson(res, 404, { error: 'Timetable has not been received yet' });
        await mappingStore.syncFromTimetable(timetable);
        const result = await syncTimetableToAmoCatalog({ timetable, amoClient, slotStore, config });
        return sendJson(res, 200, result);
      }

      if (req.method === 'GET' && url.pathname === '/api/amocrm/webhooks/log') {
        requireServiceApiKey(req, config);
        return sendJson(res, 200, await storage.readJson('amocrm-webhooks.json', { events: [] }));
      }

      return sendJson(res, 404, { error: 'Not found' });
    } catch (error) {
      return handleError(res, error, logger);
    }
  }

  handle.close = () => {
    if (workerTimer) clearInterval(workerTimer);
    storage.close?.();
  };

  return handle;

  async function applyRuntimeSettings(settings = null) {
    const currentSettings = settings || await settingsStore.get();
    const effective = buildEffectiveConfig(baseConfig, currentSettings);
    for (const key of Object.keys(effective)) config[key] = effective[key];
    if (amoClient) amoClient.config = config;
    return currentSettings;
  }
}

export function startServer(config, logger) {
  const app = buildApp(config, logger);
  const server = createServer((req, res) => {
    app(req, res);
  });
  server.on('close', () => app.close?.());
  server.listen(config.port, () => {
    logger.info(`IDENT amoCRM integration listening on ${config.port}`);
  });
  return server;
}

async function loadTicketsForIdent({ ticketQueue, mappingStore, jobQueue, amoClient, tokenStore, config, range, logger }) {
  const amoTokenReady = amoClient && (await hasAmoAccessToken(tokenStore));
  if (amoTokenReady && ['api', 'both'].includes(config.amo.getTicketsSource)) {
    const leads = await amoClient.listLeads({
      updatedFrom: range.from,
      updatedTo: range.to,
      limit: range.limit || 250,
      offset: range.offset || 0
    });
    const contactIds = leads.flatMap((lead) => lead._embedded?.contacts?.map((contact) => contact.id) || []);
    const contactsById = await amoClient.listContactsByIds(contactIds);

    for (const lead of leads) {
      const contactId = lead._embedded?.contacts?.[0]?.id;
      const preview = await buildAmoLeadPreviewFromEntities({
        lead,
        contact: contactsById.get(contactId),
        mappingStore,
        config
      });

      const record = await queueTicketWithDedupe({
        ticketQueue,
        ticket: preview.validation.ticket,
        meta: {
          source: 'amo-api',
          externalId: String(lead.id),
          amoLeadId: lead.id,
          lastSourceEventAt: lead.updated_at ? new Date(lead.updated_at * 1000).toISOString() : null
        },
        config
      });

      const validationError = ticketValidationError(preview.mapping, preview.validation);
      if (validationError) {
        await ticketQueue.markFailed(record.id, validationError);
        if (record.changed || record.status !== 'failed') {
          await enqueueAmoTicketFailed({ record, jobQueue, config, reason: validationError });
        }
      }
    }
  }

  return filterTickets(await prepareTicketsForIdent({ ticketQueue, logger }), range);
}

async function hasAmoAccessToken(tokenStore) {
  try {
    const token = await tokenStore.get();
    return Boolean(token.accessToken);
  } catch {
    return false;
  }
}

async function syncAmoLeadIntoTicketQueue({ leadId, amoClient, ticketQueue, mappingStore, jobQueue, config, logger, source = 'amo-webhook' }) {
  const preview = await buildAmoLeadPreview({ leadId, amoClient, mappingStore, config });
  const record = await queueTicketWithDedupe({
    ticketQueue,
    ticket: preview.validation.ticket,
    meta: {
      source,
      externalId: String(leadId),
      amoLeadId: leadId,
      lastSourceEventAt: preview.lead.updatedAt || null
    },
    config
  });

  const validationError = ticketValidationError(preview.mapping, preview.validation);
  if (validationError) {
    await ticketQueue.markFailed(record.id, validationError);
    logger.warn('amoCRM webhook lead skipped', { leadId, reason: validationError });
    if (record.changed || record.status !== 'failed') {
      await enqueueAmoTicketFailed({ record, jobQueue, config, reason: validationError });
    }
    return { ticket: null, record: { ...record, status: 'failed', lastError: validationError }, preview };
  }

  if (record.status === 'ignored') {
    logger.info('amoCRM lead ignored as duplicate for IDENT', { leadId, ticketId: preview.validation.ticket.Id, reason: record.lastError });
    return { ticket: null, record, preview };
  }

  logger.info('amoCRM webhook lead queued for IDENT', { leadId, ticketId: preview.validation.ticket.Id });
  return { ticket: preview.validation.ticket, record, preview };
}

async function queueTicketWithDedupe({
  ticketQueue,
  ticket,
  meta = {},
  config,
  reserveSlot = false,
  timetable = null,
  branchId = null
}) {
  if (reserveSlot) {
    return ticketQueue.reserveAndUpsert(ticket, meta, {
      timetable,
      branchId,
      dedupeEnabled: Boolean(config.dedupe?.enabled),
      dedupeWindowMinutes: config.dedupe?.windowMinutes,
      holdMinutes: config.ident.reservationMinutes,
      maxTimetableAgeMinutes: config.ident.timetableMaxAgeMinutes
    });
  }
  if (!config.dedupe?.enabled) return ticketQueue.upsert(ticket, meta);
  const duplicate = await ticketQueue.findDuplicate(ticket, {
    excludeId: ticket.Id,
    windowMinutes: config.dedupe.windowMinutes
  });
  if (!duplicate) return ticketQueue.upsert(ticket, meta);

  return ticketQueue.upsert(ticket, {
    ...meta,
    status: 'ignored',
    lastError: `Duplicate of ${duplicate.id}`
  });
}

async function getIdentDbStatus({ identDbClient }) {
  const summary = identDbClient.summary();
  if (!summary.enabled || !summary.configured) {
    return {
      ok: false,
      ready: false,
      status: summary.enabled ? 'not_configured' : 'disabled',
      connection: summary,
      checkedAt: new Date().toISOString()
    };
  }

  try {
    const connection = await identDbClient.testConnection();
    return {
      ok: Boolean(connection.ok),
      ready: Boolean(connection.ok),
      status: connection.ok ? 'ok' : 'error',
      connection: {
        ...summary,
        ...connection
      }
    };
  } catch (error) {
    return {
      ok: false,
      ready: false,
      status: 'error',
      connection: summary,
      error: error.message,
      checkedAt: new Date().toISOString()
    };
  }
}

async function getIdentDbMapping(storage) {
  return normalizeIdentDbMapping(await storage.readJson('ident-db-mapping.json', defaultIdentDbMapping()));
}

function summarizeEffectiveSettings(config) {
  return {
    amo: {
      pipelineId: config.amo.pipelineId,
      statusId: config.amo.statusId,
      createPipelineId: config.amo.createPipelineId,
      createStatusId: config.amo.createStatusId,
      sentStatusId: config.amo.sentStatusId,
      failedStatusId: config.amo.failedStatusId,
      timetableCatalogId: config.amo.timetableCatalogId,
      fields: config.amo.fields,
      timetableFields: config.amo.timetableFields,
      rateLimit: config.amo.rateLimit
    },
    dedupe: config.dedupe
  };
}

async function buildAmoLeadPreview({ leadId, amoClient, mappingStore, config }) {
  const lead = await amoClient.getLeadById(leadId);
  const contactId = lead._embedded?.contacts?.[0]?.id;
  const contactsById = await amoClient.listContactsByIds(contactId ? [contactId] : []);
  return buildAmoLeadPreviewFromEntities({
    lead,
    contact: contactsById.get(contactId),
    mappingStore,
    config
  });
}

async function buildAmoLeadPreviewFromEntities({ lead, contact, mappingStore, config }) {
  const rawTicket = leadToIdentTicket(lead, contact, config);
  const mappedTicket = { ...rawTicket };
  const mapping = await applyDoctorMapping(mappedTicket, mappingStore, {
    amoDoctorId: rawTicket.AmoDoctorId,
    requireDoctorMapping: config.ident.requireDoctorMapping
  });
  delete mappedTicket.AmoDoctorId;
  const validation = normalizeAndValidateTicket(mappedTicket);

  return {
    readyForIdent: Boolean(mapping.ok && validation.ok),
    lead: summarizeAmoLead(lead),
    contact: summarizeAmoContact(contact),
    rawTicket,
    mappedTicket,
    mapping,
    validation
  };
}

function summarizeAmoLead(lead) {
  return {
    id: lead.id,
    name: lead.name || null,
    pipelineId: lead.pipeline_id || null,
    statusId: lead.status_id || null,
    createdAt: lead.created_at ? new Date(lead.created_at * 1000).toISOString() : null,
    updatedAt: lead.updated_at ? new Date(lead.updated_at * 1000).toISOString() : null,
    contactIds: lead._embedded?.contacts?.map((contact) => contact.id).filter(Boolean) || [],
    customFields: summarizeCustomFields(lead.custom_fields_values)
  };
}

function summarizeAmoContact(contact) {
  if (!contact) return null;
  return {
    id: contact.id,
    name: contact.name || [contact.last_name, contact.first_name].filter(Boolean).join(' ') || null,
    customFields: summarizeCustomFields(contact.custom_fields_values)
  };
}

function summarizeCustomFields(fields) {
  return (fields || []).map((field) => ({
    fieldId: field.field_id || null,
    fieldCode: field.field_code || null,
    fieldName: field.field_name || null,
    values: (field.values || []).map((item) => ({
      value: item.value ?? null,
      enumId: item.enum_id || null,
      enumCode: item.enum_code || null
    }))
  }));
}

function ticketValidationError(mappingResult, validation) {
  if (!mappingResult.ok) return mappingResult.reason;
  if (!validation.ok) return validation.errors.join('; ');
  return null;
}

async function prepareTicketsForIdent({ ticketQueue, logger }) {
  const records = await ticketQueue.listRecords({ status: ['queued', 'sent_to_ident'] });
  const tickets = [];
  for (const record of records) {
    const validation = normalizeAndValidateIdentTicket(record.ticket);
    if (!validation.ok) {
      await ticketQueue.markFailed(record.id, validation.errors.join('; '));
      logger.warn('Queued ticket failed IDENT validation', { id: record.id, errors: validation.errors });
      continue;
    }
    tickets.push(validation.ticket);
  }
  return tickets;
}

async function enqueueAmoTicketsSent({ records, jobQueue, config }) {
  for (const record of records) {
    if (!record.amoLeadId) continue;
    await jobQueue.enqueue(
      'amocrm.lead_sent_feedback',
      { leadId: record.amoLeadId, ticketId: record.id },
      {
        dedupeKey: `amocrm.lead_sent_feedback:${record.amoLeadId}:${record.id}:${record.sentCount}`,
        maxAttempts: config.jobs.maxAttempts
      }
    );
  }
}

async function enqueueAmoTicketFailed({ record, jobQueue, config, reason }) {
  if (!record.amoLeadId) return;
  await jobQueue.enqueue(
    'amocrm.lead_failed_feedback',
    { leadId: record.amoLeadId, ticketId: record.id, reason },
    {
      dedupeKey: `amocrm.lead_failed_feedback:${record.amoLeadId}:${record.id}:${record.fingerprint}`,
      maxAttempts: config.jobs.maxAttempts
    }
  );
}

async function processDueJobs({ jobQueue, ticketQueue, mappingStore, storage, slotStore, amoClient, config, logger }) {
  const dueJobs = await jobQueue.due(config.jobs.batchSize);
  const result = { processed: 0, succeeded: 0, failed: 0 };

  for (const dueJob of dueJobs) {
    const job = await jobQueue.markRunning(dueJob.id);
    if (!job) continue;
    result.processed += 1;
    try {
      const jobResult = await processJob({ job, jobQueue, ticketQueue, mappingStore, storage, slotStore, amoClient, config, logger });
      await jobQueue.complete(job.id, jobResult);
      result.succeeded += 1;
    } catch (error) {
      await jobQueue.fail(job.id, error, config.jobs.retryBaseDelayMs);
      result.failed += 1;
      logger.error('Integration job failed', { id: job.id, type: job.type, message: error.message });
    }
  }

  return result;
}

async function processJob({ job, jobQueue, ticketQueue, mappingStore, storage, slotStore, amoClient, config, logger }) {
  switch (job.type) {
    case 'amocrm.import_lead': {
      requireAmoClient(amoClient);
      const result = await syncAmoLeadIntoTicketQueue({
        leadId: job.payload.leadId,
        amoClient,
        ticketQueue,
        mappingStore,
        jobQueue,
        config,
        logger
      });
      return { ticketId: result.ticket?.Id || null, readyForIdent: result.preview.readyForIdent };
    }
    case 'amocrm.lead_sent_feedback': {
      requireAmoClient(amoClient);
      const { leadId, ticketId } = job.payload;
      if (config.amo.addNotes) {
        await amoClient.addLeadNote(leadId, `Заявка передана в IDENT через GetTickets. TicketId: ${ticketId}`);
      }
      if (config.amo.sentStatusId) {
        await amoClient.updateLeadStatus(leadId, config.amo.sentStatusId, config.amo.pipelineId);
      }
      logger.info('amoCRM lead marked as sent to IDENT', { leadId, ticketId });
      return { leadId, ticketId };
    }
    case 'amocrm.lead_failed_feedback': {
      requireAmoClient(amoClient);
      const { leadId, ticketId, reason } = job.payload;
      if (config.amo.addNotes) {
        await amoClient.addLeadNote(leadId, `Заявка не передана в IDENT: ${reason}`);
      }
      if (config.amo.failedStatusId) {
        await amoClient.updateLeadStatus(leadId, config.amo.failedStatusId, config.amo.pipelineId);
      }
      return { leadId, ticketId };
    }
    case 'amocrm.timetable_sync': {
      requireAmoClient(amoClient);
      const timetable = await storage.readJson('timetable.json', null);
      if (!timetable) throw new Error('Timetable has not been received yet');
      await mappingStore.syncFromTimetable(timetable);
      return syncTimetableToAmoCatalog({ timetable, amoClient, slotStore, config });
    }
    default:
      throw new Error(`Unknown job type: ${job.type}`);
  }
}

function requireAmoClient(amoClient) {
  if (!amoClient) throw new Error('amoCRM is not configured');
}

function parseIdentRange(url) {
  const from = parseDateParam(url.searchParams.get('dateTimeFrom'));
  const to = parseDateParam(url.searchParams.get('dateTimeTo'));
  const limit = optionalPositiveInt(url.searchParams.get('limit'));
  const offset = optionalNonNegativeInt(url.searchParams.get('offset'));
  return { from, to, limit, offset };
}

function optionalPositiveInt(value) {
  const parsed = optionalNonNegativeInt(value);
  return parsed && parsed > 0 ? parsed : null;
}

function optionalNonNegativeInt(value) {
  if (value === null || value === '') return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

async function readJson(req, maxBytes = 2 * 1024 * 1024) {
  const chunks = [];
  let totalBytes = 0;
  for await (const chunk of req) {
    totalBytes += chunk.length;
    if (totalBytes > maxBytes) throw new BadRequestError(`Request body exceeds ${maxBytes} bytes`);
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new BadRequestError('Request body must be valid JSON');
  }
}

function requireServiceApiKey(req, config) {
  if (!config.serviceApiKey) return;
  if (req.headers['x-api-key'] !== config.serviceApiKey) {
    const error = new Error('Invalid service API key');
    error.status = 401;
    throw error;
  }
}

function requireAgentApiKey(req, config) {
  if (!config.agent.apiKey) {
    const error = new Error('AGENT_API_KEY is not configured');
    error.status = 500;
    throw error;
  }
  if (req.headers['x-agent-key'] !== config.agent.apiKey) {
    const error = new Error('Invalid agent API key');
    error.status = 401;
    throw error;
  }
}

function isTrustedAmoWidgetCallback(url, config) {
  if (!url.searchParams.get('from_widget')) return false;
  const expectedHost = normalizeHost(config.amo.baseUrl);
  const refererHost = normalizeHost(url.searchParams.get('referer'));
  const callbackClientId = url.searchParams.get('client_id');
  if (callbackClientId && callbackClientId !== config.amo.clientId) return false;
  return Boolean(expectedHost && refererHost && expectedHost === refererHost);
}

function formatAmoOAuthConfigError(status) {
  const missing = status.missingLabels?.length ? status.missingLabels.join(', ') : 'параметры OAuth';
  const callback = status.expectedRedirectUri ? ` Redirect URI: ${status.expectedRedirectUri}.` : '';
  return `OAuth amoCRM не настроен на сервере. Не заполнены: ${missing}.${callback}`;
}

function normalizeHost(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  try {
    return new URL(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`).host.toLowerCase();
  } catch {
    return '';
  }
}

function normalizeAgentDesiredInput(input = {}) {
  const result = { ...input };
  if (Object.prototype.hasOwnProperty.call(input, 'scheduleMapping')) {
    if (input.scheduleMapping === null) {
      throw new BadRequestError('scheduleMapping cannot be null; disable scheduleEnabled instead');
    }

    const mapping = normalizeIdentDbMapping(input.scheduleMapping);
    result.scheduleMapping = {
      doctorsSql: validateReadOnlySql(mapping.doctorsSql, 'doctorsSql'),
      branchesSql: validateReadOnlySql(mapping.branchesSql, 'branchesSql'),
      intervalsSql: validateReadOnlySql(mapping.intervalsSql, 'intervalsSql'),
      servicesSql: mapping.servicesSql
        ? validateReadOnlySql(mapping.servicesSql, 'servicesSql')
        : '',
      notes: mapping.notes
    };
  }

  if (Object.prototype.hasOwnProperty.call(input, 'sqlConfiguration')) {
    const dataSource = String(input.sqlConfiguration?.dataSource || '').trim();
    const database = String(input.sqlConfiguration?.database || '').trim();
    if (
      !dataSource || !database ||
      dataSource.length > 500 || database.length > 256 ||
      /[;\r\n]/.test(dataSource) || /[;\r\n]/.test(database)
    ) {
      throw new BadRequestError('sqlConfiguration requires safe dataSource and database values');
    }
    result.sqlConfiguration = { dataSource, database };
  }

  return result;
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload)
  });
  res.end(payload);
}

function sendBuffer(res, status, body, headers = {}) {
  res.writeHead(status, {
    ...headers,
    'Content-Length': body.length
  });
  res.end(body);
}

function applyCors(req, res, config) {
  const origin = req.headers.origin;
  const allowedOrigin = resolveAllowedCorsOrigin(origin, config);
  if (allowedOrigin) {
    res.setHeader('Access-Control-Allow-Origin', allowedOrigin);
    res.setHeader('Access-Control-Allow-Methods', config.cors.allowedMethods.join(', '));
    res.setHeader('Access-Control-Allow-Headers', config.cors.allowedHeaders.join(', '));
    res.setHeader('Access-Control-Max-Age', '600');
    res.setHeader('Vary', 'Origin');
  }

  if (req.method !== 'OPTIONS') return false;
  if (!origin) {
    res.writeHead(204);
    res.end();
    return true;
  }
  if (!allowedOrigin) {
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('CORS origin is not allowed');
    return true;
  }
  res.writeHead(204);
  res.end();
  return true;
}

function resolveAllowedCorsOrigin(origin, config) {
  if (!origin) return '';
  return config.cors.allowedOrigins.some((pattern) => originMatchesPattern(origin, pattern)) ? origin : '';
}

function originMatchesPattern(origin, pattern) {
  const normalizedPattern = String(pattern || '').trim();
  if (!normalizedPattern) return false;
  if (normalizedPattern === '*') return true;
  if (normalizedPattern === origin) return true;
  const escaped = normalizedPattern
    .replace(/[.+?^${}()|[\]\\]/g, '\\$&')
    .replace(/\*/g, '[^.:/]+');
  return new RegExp(`^${escaped}$`, 'i').test(origin);
}

function sendText(res, status, body) {
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': Buffer.byteLength(body)
  });
  res.end(body);
}

function sendHtml(res, status, body) {
  res.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(body)
  });
  res.end(body);
}

function handleError(res, error, logger) {
  const status = error.status || 500;
  const message = status >= 500 ? 'Internal server error' : error.message;
  logger.error(error.message, { status, stack: status >= 500 ? error.stack : undefined });
  return sendText(res, status, message);
}

function oauthHtml(message) {
  const safe = String(message).replace(/[&<>"']/g, (char) => {
    const escapes = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
    return escapes[char];
  });
  return `<!doctype html><html><head><meta charset="utf-8"><title>amoCRM OAuth</title><script>if(window.opener){window.opener.postMessage({status:${JSON.stringify(safe)}}, "*");}</script></head><body>${safe}</body></html>`;
}
