import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);

export function createStorage(config, logger = console) {
  if (config.storage?.driver === 'sqlite') {
    return new SqliteStorage({
      dbFile: config.storage.sqliteFile,
      dataDir: config.dataDir,
      migrateJson: config.storage.migrateJson,
      logger
    });
  }
  return new JsonStorage(config.dataDir);
}

export class JsonStorage {
  constructor(dataDir) {
    this.dataDir = dataDir;
  }

  async readJson(fileName, fallback) {
    const filePath = this.pathFor(fileName);
    try {
      const raw = await readFile(filePath, 'utf8');
      return parseJson(raw);
    } catch (error) {
      if (error.code === 'ENOENT') return fallback;
      throw error;
    }
  }

  async writeJson(fileName, value) {
    await mkdir(this.dataDir, { recursive: true });
    const filePath = this.pathFor(fileName);
    const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
    await rename(tempPath, filePath);
  }

  pathFor(fileName) {
    return path.join(this.dataDir, fileName);
  }
}

export class SqliteStorage {
  constructor({ dbFile, dataDir, migrateJson = true, logger = console }) {
    const { DatabaseSync } = require('node:sqlite');
    this.dbFile = dbFile;
    this.dataDir = dataDir;
    this.migrateJson = migrateJson;
    this.logger = logger;
    mkdirSync(path.dirname(dbFile), { recursive: true });
    this.db = new DatabaseSync(dbFile);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA busy_timeout = 5000;
      CREATE TABLE IF NOT EXISTS kv_store (
        key TEXT PRIMARY KEY,
        value_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    `);
    this.selectStatement = this.db.prepare('SELECT value_json FROM kv_store WHERE key = ?');
    this.upsertStatement = this.db.prepare(`
      INSERT INTO kv_store (key, value_json, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        value_json = excluded.value_json,
        updated_at = excluded.updated_at
    `);
  }

  async readJson(fileName, fallback) {
    const row = this.selectStatement.get(fileName);
    if (row?.value_json) return JSON.parse(row.value_json);

    if (this.migrateJson) {
      const migrated = this.readLegacyJson(fileName);
      if (migrated.found) {
        await this.writeJson(fileName, migrated.value);
        this.logger.info('Migrated JSON state into SQLite', { key: fileName, dbFile: this.dbFile });
        return migrated.value;
      }
    }

    return fallback;
  }

  async writeJson(fileName, value) {
    this.upsertStatement.run(fileName, JSON.stringify(value), new Date().toISOString());
  }

  pathFor(fileName) {
    return path.join(this.dataDir, fileName);
  }

  readLegacyJson(fileName) {
    const filePath = this.pathFor(fileName);
    if (!existsSync(filePath)) return { found: false, value: null };
    return { found: true, value: parseJson(readFileSync(filePath, 'utf8')) };
  }

  close() {
    this.db.close();
  }
}

export class TicketQueue {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'tickets.json';
  }

  async records() {
    const data = await this.storage.readJson(this.fileName, { records: [], tickets: [] });
    if (Array.isArray(data.records)) return data.records.map(normalizeRecord).filter(Boolean);
    if (Array.isArray(data.tickets)) {
      return data.tickets.map((ticket) => normalizeRecord({ ticket, status: 'queued' })).filter(Boolean);
    }
    return [];
  }

  async list() {
    return (await this.records()).map((record) => record.ticket);
  }

  async listQueuedTickets() {
    return (await this.records())
      .filter((record) => record.status === 'queued')
      .map((record) => record.ticket);
  }

  async listRecords({ status } = {}) {
    const statuses = Array.isArray(status) ? status : status ? [status] : null;
    const records = await this.records();
    return statuses ? records.filter((record) => statuses.includes(record.status)) : records;
  }

  async summary() {
    const records = await this.records();
    const statuses = { queued: 0, sent_to_ident: 0, failed: 0, ignored: 0 };
    for (const record of records) {
      statuses[record.status] = (statuses[record.status] || 0) + 1;
    }

    return {
      total: records.length,
      statuses,
      failed: records
        .filter((record) => record.status === 'failed')
        .slice(0, 20)
        .map((record) => ({
          id: record.id,
          source: record.source,
          amoLeadId: record.amoLeadId,
          lastError: record.lastError,
          updatedAt: record.updatedAt
        }))
    };
  }

  async add(ticket, meta = {}) {
    const record = await this.upsert(ticket, meta);
    return record.ticket;
  }

  async upsert(ticket, meta = {}) {
    const records = await this.records();
    const now = new Date().toISOString();
    const fingerprint = ticketFingerprint(ticket);
    const duplicateKey = ticketDuplicateKey(ticket);
    const index = records.findIndex((record) => record.id === ticket.Id);
    const existing = index === -1 ? null : records[index];
    const changed = !existing || existing.fingerprint !== fingerprint;
    const status = meta.status || (changed ? 'queued' : existing.status);

    const record = {
      id: ticket.Id,
      source: meta.source || existing?.source || sourceFromTicketId(ticket.Id),
      externalId: meta.externalId || existing?.externalId || externalIdFromTicketId(ticket.Id),
      amoLeadId: meta.amoLeadId || existing?.amoLeadId || amoLeadIdFromTicketId(ticket.Id),
      status,
      ticket,
      fingerprint,
      duplicateKey,
      createdAt: existing?.createdAt || now,
      updatedAt: now,
      queuedAt: changed ? now : existing?.queuedAt || now,
      sentAt: changed ? null : existing?.sentAt || null,
      sentCount: existing?.sentCount || 0,
      lastError: meta.lastError || (changed ? null : existing?.lastError || null),
      lastSourceEventAt: meta.lastSourceEventAt || existing?.lastSourceEventAt || null
    };

    if (index === -1) records.unshift(record);
    else records[index] = record;

    await this.writeRecords(records);
    return { ...record, changed };
  }

  async findDuplicate(ticket, options = {}) {
    const duplicateKey = ticketDuplicateKey(ticket);
    if (!duplicateKey) return null;
    const excludeId = options.excludeId ? String(options.excludeId) : '';
    const windowMs = Number(options.windowMinutes || 0) * 60 * 1000;
    const threshold = windowMs ? Date.now() - windowMs : 0;

    return (await this.records()).find((record) => {
      if (excludeId && record.id === excludeId) return false;
      if (!['queued', 'sent_to_ident'].includes(record.status)) return false;
      if (record.duplicateKey !== duplicateKey) return false;
      if (!threshold) return true;
      const updatedAt = new Date(record.updatedAt || record.createdAt || 0).getTime();
      return Number.isFinite(updatedAt) && updatedAt >= threshold;
    }) || null;
  }

  async markSent(ids) {
    if (!ids.length) return [];
    const idSet = new Set(ids);
    const records = await this.records();
    const now = new Date().toISOString();
    const changed = [];

    for (const record of records) {
      if (!idSet.has(record.id)) continue;
      record.status = 'sent_to_ident';
      record.sentAt = now;
      record.updatedAt = now;
      record.sentCount = Number(record.sentCount || 0) + 1;
      record.lastError = null;
      changed.push(record);
    }

    await this.writeRecords(records);
    return changed;
  }

  async markFailed(id, errorMessage) {
    const records = await this.records();
    const record = records.find((item) => item.id === id);
    if (!record) return null;
    record.status = 'failed';
    record.lastError = errorMessage;
    record.updatedAt = new Date().toISOString();
    await this.writeRecords(records);
    return record;
  }

  async requeue(id) {
    const records = await this.records();
    const record = records.find((item) => item.id === id);
    if (!record) return null;
    record.status = 'queued';
    record.queuedAt = new Date().toISOString();
    record.updatedAt = record.queuedAt;
    record.lastError = null;
    await this.writeRecords(records);
    return record;
  }

  async writeRecords(records) {
    await this.storage.writeJson(this.fileName, { updatedAt: new Date().toISOString(), records });
  }
}

export class AmoSlotStore {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'amo-slots.json';
  }

  async getMap() {
    const data = await this.storage.readJson(this.fileName, { slots: {} });
    return data.slots && typeof data.slots === 'object' ? data.slots : {};
  }

  async setMap(slots) {
    await this.storage.writeJson(this.fileName, { updatedAt: new Date().toISOString(), slots });
  }
}

export class WebhookLog {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'amocrm-webhooks.json';
  }

  async add(entry) {
    const data = await this.storage.readJson(this.fileName, { events: [] });
    const events = Array.isArray(data.events) ? data.events : [];
    events.unshift(entry);
    await this.storage.writeJson(this.fileName, {
      updatedAt: new Date().toISOString(),
      events: events.slice(0, 200)
    });
  }
}

export class IntegrationJobQueue {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'jobs.json';
  }

  async list({ status, type } = {}) {
    const data = await this.storage.readJson(this.fileName, { jobs: [] });
    let jobs = Array.isArray(data.jobs) ? data.jobs.map(normalizeJob).filter(Boolean) : [];
    if (status) jobs = jobs.filter((job) => job.status === status);
    if (type) jobs = jobs.filter((job) => job.type === type);
    return jobs;
  }

  async summary() {
    const jobs = await this.list();
    const statuses = { queued: 0, running: 0, succeeded: 0, failed: 0 };
    for (const job of jobs) statuses[job.status] = (statuses[job.status] || 0) + 1;
    return {
      total: jobs.length,
      statuses,
      failed: jobs
        .filter((job) => job.status === 'failed')
        .slice(0, 20)
        .map((job) => ({
          id: job.id,
          type: job.type,
          attempts: job.attempts,
          lastError: job.lastError,
          updatedAt: job.updatedAt
        }))
    };
  }

  async enqueue(type, payload = {}, options = {}) {
    const jobs = await this.list();
    const now = new Date().toISOString();
    const dedupeKey = options.dedupeKey || null;
    const existingIndex = dedupeKey
      ? jobs.findIndex((job) => job.dedupeKey === dedupeKey && ['queued', 'running'].includes(job.status))
      : -1;

    const job = {
      id: existingIndex === -1 ? crypto.randomUUID() : jobs[existingIndex].id,
      type,
      payload,
      status: 'queued',
      attempts: existingIndex === -1 ? 0 : jobs[existingIndex].attempts,
      maxAttempts: Number(options.maxAttempts || jobs[existingIndex]?.maxAttempts || 8),
      dedupeKey,
      nextRunAt: options.runAt || jobs[existingIndex]?.nextRunAt || now,
      createdAt: existingIndex === -1 ? now : jobs[existingIndex].createdAt,
      updatedAt: now,
      startedAt: null,
      finishedAt: null,
      lastError: null,
      result: null
    };

    if (existingIndex === -1) jobs.unshift(job);
    else jobs[existingIndex] = job;
    await this.writeJobs(jobs);
    return job;
  }

  async due(limit = 10, now = new Date()) {
    const jobs = await this.list();
    return jobs
      .filter((job) => job.status === 'queued' && new Date(job.nextRunAt).getTime() <= now.getTime())
      .sort((left, right) => new Date(left.nextRunAt) - new Date(right.nextRunAt))
      .slice(0, limit);
  }

  async markRunning(id) {
    const jobs = await this.list();
    const job = jobs.find((item) => item.id === id && item.status === 'queued');
    if (!job) return null;
    const now = new Date().toISOString();
    job.status = 'running';
    job.attempts = Number(job.attempts || 0) + 1;
    job.startedAt = now;
    job.updatedAt = now;
    await this.writeJobs(jobs);
    return job;
  }

  async complete(id, result = null) {
    const jobs = await this.list();
    const job = jobs.find((item) => item.id === id);
    if (!job) return null;
    const now = new Date().toISOString();
    job.status = 'succeeded';
    job.finishedAt = now;
    job.updatedAt = now;
    job.lastError = null;
    job.result = result;
    await this.writeJobs(jobs);
    return job;
  }

  async fail(id, error, retryBaseDelayMs = 60_000) {
    const jobs = await this.list();
    const job = jobs.find((item) => item.id === id);
    if (!job) return null;
    const now = new Date();
    const message = error?.message || String(error);
    job.lastError = message;
    job.updatedAt = now.toISOString();

    if (Number(job.attempts || 0) >= Number(job.maxAttempts || 1)) {
      job.status = 'failed';
      job.finishedAt = job.updatedAt;
    } else {
      const delay = retryBaseDelayMs * 2 ** Math.max(0, Number(job.attempts || 1) - 1);
      job.status = 'queued';
      job.nextRunAt = new Date(now.getTime() + delay).toISOString();
      job.startedAt = null;
    }

    await this.writeJobs(jobs);
    return job;
  }

  async retry(id) {
    const jobs = await this.list();
    const job = jobs.find((item) => item.id === id);
    if (!job) return null;
    const now = new Date().toISOString();
    job.status = 'queued';
    job.nextRunAt = now;
    job.updatedAt = now;
    job.startedAt = null;
    job.finishedAt = null;
    job.lastError = null;
    await this.writeJobs(jobs);
    return job;
  }

  async writeJobs(jobs) {
    await this.storage.writeJson(this.fileName, { updatedAt: new Date().toISOString(), jobs });
  }
}

function normalizeRecord(record) {
  const ticket = record?.ticket || (record?.Id ? record : null);
  if (!ticket?.Id) return null;
  const fingerprint = record.fingerprint || ticketFingerprint(ticket);
  const now = new Date().toISOString();
  return {
    id: record.id || ticket.Id,
    source: record.source || sourceFromTicketId(ticket.Id),
    externalId: record.externalId || externalIdFromTicketId(ticket.Id),
    amoLeadId: record.amoLeadId || amoLeadIdFromTicketId(ticket.Id),
    status: normalizeStatus(record.status),
    ticket,
    fingerprint,
    duplicateKey: record.duplicateKey || ticketDuplicateKey(ticket),
    createdAt: record.createdAt || now,
    updatedAt: record.updatedAt || now,
    queuedAt: record.queuedAt || record.createdAt || now,
    sentAt: record.sentAt || null,
    sentCount: Number(record.sentCount || 0),
    lastError: record.lastError || null,
    lastSourceEventAt: record.lastSourceEventAt || null
  };
}

function normalizeStatus(status) {
  return ['queued', 'sent_to_ident', 'failed', 'ignored'].includes(status) ? status : 'queued';
}

function ticketFingerprint(ticket) {
  const { DateAndTime, ...meaningfulTicket } = ticket;
  return crypto.createHash('sha256').update(stableStringify(meaningfulTicket)).digest('hex');
}

function ticketDuplicateKey(ticket) {
  const phone = normalizeDuplicateText(ticket.ClientPhone);
  const planStart = normalizeDuplicateText(ticket.PlanStart || ticket.DateAndTime);
  const doctor = normalizeDuplicateText(ticket.DoctorId || ticket.DoctorName);
  if (!phone || !planStart) return '';
  return crypto
    .createHash('sha256')
    .update(stableStringify({ phone, planStart, doctor }))
    .digest('hex');
}

function normalizeDuplicateText(value) {
  return String(value || '').toLowerCase().trim().replace(/\s+/g, ' ');
}

function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

function sourceFromTicketId(id) {
  return String(id).startsWith('amo:') ? 'amo' : 'local';
}

function externalIdFromTicketId(id) {
  const raw = String(id);
  return raw.includes(':') ? raw.slice(raw.indexOf(':') + 1) : raw;
}

function amoLeadIdFromTicketId(id) {
  const raw = String(id);
  if (!raw.startsWith('amo:')) return null;
  const parsed = Number.parseInt(raw.slice(4), 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizeJob(job) {
  if (!job?.id || !job?.type) return null;
  const now = new Date().toISOString();
  return {
    id: String(job.id),
    type: String(job.type),
    payload: job.payload && typeof job.payload === 'object' ? job.payload : {},
    status: normalizeJobStatus(job.status),
    attempts: Number(job.attempts || 0),
    maxAttempts: Number(job.maxAttempts || 8),
    dedupeKey: job.dedupeKey || null,
    nextRunAt: job.nextRunAt || now,
    createdAt: job.createdAt || now,
    updatedAt: job.updatedAt || now,
    startedAt: job.startedAt || null,
    finishedAt: job.finishedAt || null,
    lastError: job.lastError || null,
    result: job.result || null
  };
}

function normalizeJobStatus(status) {
  return ['queued', 'running', 'succeeded', 'failed'].includes(status) ? status : 'queued';
}

function parseJson(raw) {
  return JSON.parse(String(raw).replace(/^\uFEFF/, ''));
}
