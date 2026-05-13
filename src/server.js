import { createServer } from 'node:http';
import { URL } from 'node:url';
import { AmoClient } from './amocrm/client.js';
import { buildAmoAuthorizeUrl, OAuthStateStore, verifyDisconnectSignature } from './amocrm/oauth.js';
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
import { normalizeAndValidateTicket } from './ident/ticket-validation.js';
import {
  BadRequestError,
  filterTickets,
  normalizeBookingTicket,
  normalizeTimeTablePayload,
  validateIdentKey
} from './ident/contracts.js';
import { bookingToAmoLead, leadToIdentTicket } from './ident/mappers.js';
import { AmoSlotStore, createStorage, IntegrationJobQueue, TicketQueue, WebhookLog } from './storage.js';

export function buildApp(config, logger) {
  const storage = createStorage(config, logger);
  const ticketQueue = new TicketQueue(storage);
  const jobQueue = new IntegrationJobQueue(storage);
  const mappingStore = new MappingStore(storage);
  const slotStore = new AmoSlotStore(storage);
  const webhookLog = new WebhookLog(storage);
  const oauthStateStore = new OAuthStateStore(storage);
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

  async function handle(req, res) {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

    try {
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

        const body = await readJson(req);
        const timetable = normalizeTimeTablePayload(body);
        await storage.writeJson('timetable.json', timetable);
        await mappingStore.syncFromTimetable(timetable);
        logger.info('IDENT timetable received', timetable.Summary);

        if (config.amo.syncTimetableToCatalog) {
          await jobQueue.enqueue('amocrm.timetable_sync', {}, {
            dedupeKey: 'amocrm.timetable_sync',
            maxAttempts: config.jobs.maxAttempts
          });
        }

        return sendText(res, 200, 'OK');
      }

      if (req.method === 'GET' && url.pathname === '/GetTickets') {
        const auth = validateIdentKey(req, config);
        if (!auth.ok) return sendText(res, auth.status, auth.message);

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
        return sendJson(res, 200, timetable);
      }

      if (req.method === 'GET' && url.pathname === '/api/free-slots') {
        requireServiceApiKey(req, config);
        const timetable = await storage.readJson('timetable.json', null);
        if (!timetable) return sendJson(res, 404, { error: 'Timetable has not been received yet' });
        return sendJson(res, 200, {
          receivedAt: timetable.receivedAt,
          Doctors: timetable.Doctors,
          Branches: timetable.Branches,
          Intervals: timetable.Intervals.filter((item) => !item.IsBusy)
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
          amoClient
        }));
      }

      if (req.method === 'POST' && url.pathname === '/api/bookings') {
        requireServiceApiKey(req, config);
        const body = await readJson(req);
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
        if (amoClient) {
          amoLead = await amoClient.createLeadWithContact(bookingToAmoLead(validation.ticket, config));
          if (amoLead?.id) validation.ticket.Id = `amo:${amoLead.id}`;
        }

        await ticketQueue.add(validation.ticket, { source: amoLead?.id ? 'api-booking-amo' : 'api-booking', amoLeadId: amoLead?.id || null });
        logger.info('Booking queued for IDENT', { id: validation.ticket.Id, amoLeadId: amoLead?.id || null });
        return sendJson(res, 201, { ticket: validation.ticket, amoLeadId: amoLead?.id || null });
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

      if (req.method === 'POST' && url.pathname === '/api/tickets/requeue') {
        requireServiceApiKey(req, config);
        const body = await readJson(req);
        if (!body.id) return sendJson(res, 400, { error: 'id is required' });
        const record = await ticketQueue.requeue(String(body.id));
        if (!record) return sendJson(res, 404, { error: 'Ticket not found' });
        return sendJson(res, 200, { record });
      }

      if (req.method === 'GET' && url.pathname === '/oauth/amocrm/url') {
        requireServiceApiKey(req, config);
        const state = await oauthStateStore.create();
        return sendJson(res, 200, {
          url: buildAmoAuthorizeUrl(config, state, url.searchParams.get('mode') || 'popup'),
          state,
          redirectUri: config.amo.redirectUri
        });
      }

      if (req.method === 'GET' && url.pathname === '/oauth/amocrm/callback') {
        if (url.searchParams.get('error')) {
          return sendHtml(res, 400, oauthHtml('amoCRM authorization rejected'));
        }
        const stateOk = await oauthStateStore.consume(url.searchParams.get('state'));
        if (!stateOk) return sendHtml(res, 400, oauthHtml('Invalid OAuth state'));
        if (!amoClient) return sendHtml(res, 500, oauthHtml('amoCRM OAuth is not configured'));

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

      const record = await ticketQueue.upsert(preview.validation.ticket, {
        source: 'amo-api',
        externalId: String(lead.id),
        amoLeadId: lead.id,
        lastSourceEventAt: lead.updated_at ? new Date(lead.updated_at * 1000).toISOString() : null
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

  return filterTickets(await prepareQueuedTicketsForIdent({ ticketQueue, logger }), range);
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
  const record = await ticketQueue.upsert(preview.validation.ticket, {
    source,
    externalId: String(leadId),
    amoLeadId: leadId,
    lastSourceEventAt: preview.lead.updatedAt || null
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

  logger.info('amoCRM webhook lead queued for IDENT', { leadId, ticketId: preview.validation.ticket.Id });
  return { ticket: preview.validation.ticket, record, preview };
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

async function prepareQueuedTicketsForIdent({ ticketQueue, logger }) {
  const records = await ticketQueue.listRecords({ status: 'queued' });
  const tickets = [];
  for (const record of records) {
    const validation = normalizeAndValidateTicket(record.ticket);
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

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
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

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload)
  });
  res.end(payload);
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
