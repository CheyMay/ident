import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import path from 'node:path';
import {
  assertBookableWindow,
  assertTimetableFresh,
  blockingReservation,
  createReservation,
  extendReservation,
  overlayReservations,
  reconcileReservations as reconcileSlotReservations,
  releaseReservation
} from './ident/slot-reservations.js';

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
  constructor(storage, options = {}) {
    this.storage = storage;
    this.fileName = 'tickets.json';
    this.mutationChain = Promise.resolve();
    this.reservationMinutes = positiveNumber(options.reservationMinutes, 720);
    this.robotFailureHoldMinutes = positiveNumber(options.robotFailureHoldMinutes, 60);
    this.timetableMaxAgeMinutes = nonNegativeNumber(options.timetableMaxAgeMinutes, 30);
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
    const now = new Date();
    const statuses = {
      queued: 0,
      sent_to_ident: 0,
      failed: 0,
      ignored: 0,
      robot_processing: 0,
      robot_completed: 0,
      robot_failed: 0
    };
    for (const record of records) {
      statuses[record.status] = (statuses[record.status] || 0) + 1;
    }
    const queued = records
      .filter((record) => record.status === 'queued')
      .sort((left, right) => new Date(left.queuedAt || left.createdAt) - new Date(right.queuedAt || right.createdAt));
    const oldestQueuedAt = queued[0]?.queuedAt || queued[0]?.createdAt || null;
    const oldestQueuedAgeSeconds = oldestQueuedAt
      ? Math.max(0, Math.round((now.getTime() - new Date(oldestQueuedAt).getTime()) / 1000))
      : null;
    const staleRobotClaims = records.filter((record) => {
      if (record.status !== 'robot_processing') return false;
      const leaseUntil = new Date(record.robotLeaseUntil || 0);
      return Number.isNaN(leaseUntil.getTime()) || leaseUntil <= now;
    }).length;

    return {
      total: records.length,
      statuses,
      oldestQueuedAt,
      oldestQueuedAgeSeconds,
      staleRobotClaims,
      failed: records
        .filter((record) => ['failed', 'robot_failed'].includes(record.status))
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
    const result = this.upsertIntoRecords(records, ticket, meta);
    await this.writeRecords(records);
    return result;
  }

  async reserveAndUpsert(ticket, meta = {}, options = {}) {
    return this.runExclusive(async () => {
      const records = await this.records();
      const duplicateKey = ticketDuplicateKey(ticket);
      const windowMs = Number(options.dedupeWindowMinutes || 0) * 60 * 1000;
      const threshold = windowMs ? Date.now() - windowMs : 0;
      const duplicate = options.dedupeEnabled && duplicateKey
        ? records.find((record) => {
            if (record.id === ticket.Id) return false;
            if (!['queued', 'sent_to_ident', 'robot_processing', 'robot_completed'].includes(record.status)) return false;
            if (record.duplicateKey !== duplicateKey) return false;
            if (!threshold) return true;
            const updatedAt = new Date(record.updatedAt || record.createdAt || 0).getTime();
            return Number.isFinite(updatedAt) && updatedAt >= threshold;
          })
        : null;

      if (duplicate) {
        const ignored = this.upsertIntoRecords(records, ticket, {
          ...meta,
          status: 'ignored',
          lastError: `Duplicate of ${duplicate.id}`
        });
        if (ignored.reservation) releaseReservation(ignored.reservation, new Date(), 'duplicate');
        await this.writeRecords(records);
        return ignored;
      }

      const branchId = options.branchId ?? null;
      assertBookableWindow({
        timetable: options.timetable,
        ticket,
        branchId,
        records,
        excludeId: ticket.Id,
        maxTimetableAgeMinutes: options.maxTimetableAgeMinutes ?? this.timetableMaxAgeMinutes
      });
      const result = this.upsertIntoRecords(records, ticket, meta);
      const storedRecord = records.find((record) => record.id === ticket.Id);
      storedRecord.branchId = branchId;
      storedRecord.reservation = createReservation(ticket, branchId, {
        holdMinutes: options.holdMinutes ?? this.reservationMinutes
      });
      result.reservation = storedRecord.reservation;
      await this.writeRecords(records);
      return result;
    });
  }

  upsertIntoRecords(records, ticket, meta = {}) {
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
      branchId: meta.branchId ?? existing?.branchId ?? null,
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
      lastSourceEventAt: meta.lastSourceEventAt || existing?.lastSourceEventAt || null,
      robotAgentId: changed ? null : existing?.robotAgentId || null,
      robotClaimedAt: changed ? null : existing?.robotClaimedAt || null,
      robotLeaseUntil: changed ? null : existing?.robotLeaseUntil || null,
      robotCompletedAt: changed ? null : existing?.robotCompletedAt || null,
      robotResult: changed ? null : existing?.robotResult || null,
      reservation: changed ? null : existing?.reservation || null
    };

    if (index === -1) records.unshift(record);
    else records[index] = record;

    return { ...record, changed };
  }

  async timetableWithReservations(timetable) {
    return overlayReservations(timetable, await this.records());
  }

  async reconcileReservations(timetable) {
    return this.runExclusive(async () => {
      const records = await this.records();
      const changed = reconcileSlotReservations(records, timetable);
      if (changed) await this.writeRecords(records);
      return changed;
    });
  }

  async runExclusive(operation) {
    const previous = this.mutationChain;
    let release;
    this.mutationChain = new Promise((resolve) => { release = resolve; });
    await previous;
    try {
      return await operation();
    } finally {
      release();
    }
  }

  async findDuplicate(ticket, options = {}) {
    const duplicateKey = ticketDuplicateKey(ticket);
    if (!duplicateKey) return null;
    const excludeId = options.excludeId ? String(options.excludeId) : '';
    const windowMs = Number(options.windowMinutes || 0) * 60 * 1000;
    const threshold = windowMs ? Date.now() - windowMs : 0;

    return (await this.records()).find((record) => {
      if (excludeId && record.id === excludeId) return false;
      if (!['queued', 'sent_to_ident', 'robot_processing', 'robot_completed'].includes(record.status)) return false;
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
      if (!idSet.has(record.id) || record.status !== 'queued') continue;
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
    if (record.reservation) releaseReservation(record.reservation, new Date(), 'failed');
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
    record.robotAgentId = null;
    record.robotClaimedAt = null;
    record.robotLeaseUntil = null;
    record.robotCompletedAt = null;
    record.robotResult = null;
    if (record.reservation) {
      extendReservation(record.reservation, this.reservationDeadline(), 'active');
    }
    await this.writeRecords(records);
    return record;
  }

  async releaseExpiredRobotClaims() {
    const records = await this.records();
    const now = new Date();
    let released = 0;
    for (const record of records) {
      if (record.status !== 'robot_processing') continue;
      const leaseUntil = new Date(record.robotLeaseUntil || 0);
      if (!Number.isNaN(leaseUntil.getTime()) && leaseUntil > now) continue;
      record.status = 'queued';
      record.robotAgentId = null;
      record.robotClaimedAt = null;
      record.robotLeaseUntil = null;
      record.updatedAt = now.toISOString();
      if (record.reservation) extendReservation(record.reservation, this.reservationDeadline(now), 'active');
      released += 1;
    }
    if (released) await this.writeRecords(records);
    return released;
  }

  async claimForRobot(agentId, leaseSeconds = 300, timetable = null) {
    const normalizedAgentId = String(agentId || '').trim();
    if (!normalizedAgentId) return null;

    return this.runExclusive(async () => {
      const records = await this.records();
      const now = new Date();
      for (const record of records) {
        if (record.status !== 'robot_processing') continue;
        const leaseUntil = new Date(record.robotLeaseUntil || 0);
        if (Number.isNaN(leaseUntil.getTime()) || leaseUntil <= now) {
          record.status = 'queued';
          record.robotAgentId = null;
          record.robotClaimedAt = null;
          record.robotLeaseUntil = null;
          record.updatedAt = now.toISOString();
          if (record.reservation) extendReservation(record.reservation, this.reservationDeadline(now), 'active');
        }
      }

      const candidates = records
        .filter((item) => item.status === 'queued')
        .sort((left, right) => new Date(left.queuedAt || left.createdAt) - new Date(right.queuedAt || right.createdAt));
      if (!candidates.length) {
        await this.writeRecords(records);
        return null;
      }

      assertTimetableFresh(timetable, this.timetableMaxAgeMinutes, now);
      reconcileSlotReservations(records, timetable, now);
      let record = null;
      if (timetable && Array.isArray(timetable.Intervals)) {
        for (const candidate of candidates) {
          try {
            assertBookableWindow({
              timetable,
              ticket: candidate.ticket,
              branchId: candidate.branchId,
              records,
              excludeId: candidate.id,
              maxTimetableAgeMinutes: this.timetableMaxAgeMinutes,
              now
            });
            if (blockingReservation(candidate, now)) {
              extendReservation(candidate.reservation, this.reservationDeadline(now), 'active');
            } else {
              candidate.reservation = createReservation(candidate.ticket, candidate.branchId, {
                now,
                holdMinutes: this.reservationMinutes
              });
            }
            record = candidate;
            break;
          } catch (error) {
            candidate.status = 'robot_failed';
            candidate.updatedAt = now.toISOString();
            candidate.lastError = error.message;
            if (candidate.reservation) releaseReservation(candidate.reservation, now, 'slot_unavailable_before_robot');
          }
        }
      }

      if (!record) {
        await this.writeRecords(records);
        return null;
      }

      record.status = 'robot_processing';
      record.robotAgentId = normalizedAgentId;
      record.robotClaimedAt = now.toISOString();
      record.robotLeaseUntil = new Date(now.getTime() + Math.max(30, Number(leaseSeconds || 300)) * 1000).toISOString();
      if (record.reservation) {
        extendReservation(record.reservation, new Date(new Date(record.robotLeaseUntil).getTime() + 60_000), 'active');
      }
      record.updatedAt = record.robotClaimedAt;
      record.lastError = null;
      await this.writeRecords(records);
      return record;
    });
  }

  async completeRobot(id, agentId, result = null) {
    return this.runExclusive(async () => {
      const records = await this.records();
      const record = records.find((item) => item.id === String(id));
      if (!record || record.status !== 'robot_processing' || record.robotAgentId !== String(agentId)) return null;
      const now = new Date().toISOString();
      record.status = 'robot_completed';
      record.robotCompletedAt = now;
      record.robotLeaseUntil = null;
      record.robotResult = result && typeof result === 'object' ? result : null;
      if (record.reservation && record.reservation.status !== 'confirmed') {
        extendReservation(record.reservation, new Date(Date.now() + 30 * 60_000), 'awaiting_timetable');
      }
      record.updatedAt = now;
      record.lastError = null;
      await this.writeRecords(records);
      return record;
    });
  }

  async failRobot(id, agentId, errorMessage) {
    return this.runExclusive(async () => {
      const records = await this.records();
      const record = records.find((item) => item.id === String(id));
      if (!record || record.status !== 'robot_processing' || record.robotAgentId !== String(agentId)) return null;
      const now = new Date().toISOString();
      record.status = 'robot_failed';
      record.robotLeaseUntil = null;
      record.updatedAt = now;
      record.lastError = String(errorMessage || 'Robot failed');
      if (record.reservation) {
        extendReservation(
          record.reservation,
          new Date(Date.now() + this.robotFailureHoldMinutes * 60_000),
          'awaiting_review'
        );
      }
      await this.writeRecords(records);
      return record;
    });
  }

  async deferRobot(id, agentId, reason = 'User activity detected') {
    return this.runExclusive(async () => {
      const records = await this.records();
      const record = records.find((item) => item.id === String(id));
      if (!record || record.status !== 'robot_processing' || record.robotAgentId !== String(agentId)) return null;
      const now = new Date();
      record.status = 'queued';
      record.queuedAt = now.toISOString();
      record.updatedAt = record.queuedAt;
      record.robotAgentId = null;
      record.robotClaimedAt = null;
      record.robotLeaseUntil = null;
      record.lastError = String(reason || 'Robot execution deferred');
      if (record.reservation) extendReservation(record.reservation, this.reservationDeadline(now), 'active');
      await this.writeRecords(records);
      return record;
    });
  }

  async writeRecords(records) {
    await this.storage.writeJson(this.fileName, { updatedAt: new Date().toISOString(), records });
  }

  reservationDeadline(now = new Date()) {
    return new Date(now.getTime() + this.reservationMinutes * 60_000);
  }
}

function positiveNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function nonNegativeNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

export class AgentStatusStore {
  constructor(storage, offlineAfterSeconds = 180) {
    this.storage = storage;
    this.fileName = 'agents.json';
    this.offlineAfterSeconds = Math.max(30, Number(offlineAfterSeconds || 180));
  }

  async heartbeat(payload = {}) {
    const agentId = normalizeAgentId(payload.agentId);
    const data = await this.read();
    const now = new Date().toISOString();
    const existing = data.agents[agentId] || {};
    data.agents[agentId] = {
      agentId,
      deviceName: cleanAgentText(payload.deviceName, 120),
      version: cleanAgentText(payload.version, 40),
      startedAt: cleanAgentDate(payload.startedAt),
      lastSeenAt: now,
      status: cleanAgentText(payload.status, 40) || 'online',
      schedule: normalizeAgentSection(payload.schedule),
      schema: normalizeAgentSection(payload.schema),
      robot: normalizeAgentSection(payload.robot),
      update: normalizeAgentSection(payload.update),
      diagnostics: normalizeAgentSection(payload.diagnostics),
      system: normalizeAgentSection(payload.system),
      firstSeenAt: existing.firstSeenAt || now
    };
    data.updatedAt = now;
    await this.write(data);
    return {
      agent: this.withOnlineState(data.agents[agentId]),
      desired: this.desiredForData(data, agentId)
    };
  }

  async status() {
    const data = await this.read();
    return {
      updatedAt: data.updatedAt,
      agents: Object.values(data.agents)
        .map((agent) => this.withOnlineState(agent))
        .sort((left, right) => String(right.lastSeenAt).localeCompare(String(left.lastSeenAt))),
      desired: Object.fromEntries(
        Object.keys(data.desired).map((agentId) => [agentId, this.desiredForData(data, agentId)])
      )
    };
  }

  async desiredFor(agentId) {
    const normalized = normalizeAgentId(agentId);
    return this.desiredForData(await this.read(), normalized);
  }

  async setDesired(agentId, input = {}) {
    const normalized = normalizeAgentId(agentId);
    const data = await this.read();
    const existing = this.desiredForData(data, normalized);
    const now = new Date().toISOString();
    const mappingProvided = Object.prototype.hasOwnProperty.call(input, 'scheduleMapping');
    const sqlConfigurationProvided = Object.prototype.hasOwnProperty.call(input, 'sqlConfiguration');
    const updateProvided = Object.prototype.hasOwnProperty.call(input, 'update');
    data.desired[normalized] = {
      scheduleEnabled: typeof input.scheduleEnabled === 'boolean' ? input.scheduleEnabled : existing.scheduleEnabled,
      robotEnabled: typeof input.robotEnabled === 'boolean' ? input.robotEnabled : existing.robotEnabled,
      scheduleMapping: mappingProvided
        ? normalizeDesiredScheduleMapping(input.scheduleMapping)
        : existing.scheduleMapping,
      mappingRevision: mappingProvided ? now : existing.mappingRevision,
      sqlConfiguration: sqlConfigurationProvided
        ? normalizeDesiredSqlConfiguration(input.sqlConfiguration)
        : existing.sqlConfiguration,
      sqlConfigurationRevision: sqlConfigurationProvided ? now : existing.sqlConfigurationRevision,
      scheduleRequestRevision: input.requestScheduleNow === true ? now : existing.scheduleRequestRevision,
      diagnosticsRequestRevision: input.requestDiagnosticsNow === true ? now : existing.diagnosticsRequestRevision,
      sqlDiscoveryRequestRevision: input.requestSqlDiscovery === true ? now : existing.sqlDiscoveryRequestRevision,
      restartRequestRevision: input.requestRestart === true ? now : existing.restartRequestRevision,
      update: updateProvided ? normalizeDesiredUpdate(input.update) : existing.update,
      updatedAt: now
    };
    data.updatedAt = data.desired[normalized].updatedAt;
    await this.write(data);
    return data.desired[normalized];
  }

  async isRobotConfigured(agentId) {
    const normalized = normalizeAgentId(agentId);
    const data = await this.read();
    const agent = data.agents[normalized];
    if (!agent) return false;
    const current = this.withOnlineState(agent);
    return current.online && current.robot?.configured === true;
  }

  async isRobotModeEnabled(agentId) {
    const normalized = normalizeAgentId(agentId);
    const data = await this.read();
    const agent = data.agents[normalized];
    return (
      this.desiredForData(data, normalized).robotEnabled === true &&
      Boolean(agent) &&
      this.withOnlineState(agent).online &&
      agent.robot?.configured === true
    );
  }

  async hasRobotModeEnabled() {
    const data = await this.read();
    return Object.entries(data.desired).some(([agentId, desired]) => {
      const agent = data.agents[agentId];
      return (
        desired?.robotEnabled === true &&
        Boolean(agent) &&
        this.withOnlineState(agent).online &&
        agent.robot?.configured === true
      );
    });
  }

  withOnlineState(agent) {
    const ageSeconds = agent?.lastSeenAt
      ? Math.max(0, Math.round((Date.now() - new Date(agent.lastSeenAt).getTime()) / 1000))
      : null;
    return {
      ...agent,
      online: ageSeconds !== null && ageSeconds <= this.offlineAfterSeconds,
      ageSeconds
    };
  }

  desiredForData(data, agentId) {
    const stored = data.desired[agentId] || {};
    return {
      scheduleEnabled: typeof stored.scheduleEnabled === 'boolean' ? stored.scheduleEnabled : true,
      robotEnabled: typeof stored.robotEnabled === 'boolean' ? stored.robotEnabled : false,
      scheduleMapping: normalizeDesiredScheduleMapping(stored.scheduleMapping),
      mappingRevision: cleanAgentDate(stored.mappingRevision),
      sqlConfiguration: normalizeDesiredSqlConfiguration(stored.sqlConfiguration),
      sqlConfigurationRevision: cleanAgentDate(stored.sqlConfigurationRevision),
      scheduleRequestRevision: cleanAgentDate(stored.scheduleRequestRevision),
      diagnosticsRequestRevision: cleanAgentDate(stored.diagnosticsRequestRevision),
      sqlDiscoveryRequestRevision: cleanAgentDate(stored.sqlDiscoveryRequestRevision),
      restartRequestRevision: cleanAgentDate(stored.restartRequestRevision),
      update: normalizeDesiredUpdate(stored.update),
      updatedAt: cleanAgentDate(stored.updatedAt)
    };
  }

  async read() {
    const data = await this.storage.readJson(this.fileName, { agents: {}, desired: {}, updatedAt: null });
    return {
      agents: data.agents && typeof data.agents === 'object' ? data.agents : {},
      desired: data.desired && typeof data.desired === 'object' ? data.desired : {},
      updatedAt: data.updatedAt || null
    };
  }

  async write(data) {
    await this.storage.writeJson(this.fileName, data);
  }
}

export class AgentDiagnosticsStore {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'agent-diagnostics.json';
  }

  async put(agentId, report) {
    const normalizedAgentId = normalizeAgentId(agentId);
    const normalizedReport = normalizeAgentDiagnostics(report);
    const data = await this.read();
    const now = new Date().toISOString();
    data.reports[normalizedAgentId] = {
      agentId: normalizedAgentId,
      receivedAt: now,
      ...normalizedReport
    };
    data.updatedAt = now;
    await this.storage.writeJson(this.fileName, data);
    return data.reports[normalizedAgentId];
  }

  async get(agentId) {
    const data = await this.read();
    return data.reports[normalizeAgentId(agentId)] || null;
  }

  async read() {
    const data = await this.storage.readJson(this.fileName, { reports: {}, updatedAt: null });
    return {
      reports: data.reports && typeof data.reports === 'object' ? data.reports : {},
      updatedAt: data.updatedAt || null
    };
  }
}

export class AgentSchemaStore {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'agent-schemas.json';
  }

  async put(agentId, schema) {
    const normalizedAgentId = normalizeAgentId(agentId);
    const normalizedSchema = normalizeAgentSchema(schema);
    const data = await this.read();
    const now = new Date().toISOString();
    const record = {
      agentId: normalizedAgentId,
      receivedAt: now,
      ...normalizedSchema
    };
    data.schemas[normalizedAgentId] = record;
    data.updatedAt = now;
    await this.storage.writeJson(this.fileName, data);
    return record;
  }

  async get(agentId) {
    const normalizedAgentId = normalizeAgentId(agentId);
    const data = await this.read();
    return data.schemas[normalizedAgentId] || null;
  }

  async read() {
    const data = await this.storage.readJson(this.fileName, { schemas: {}, updatedAt: null });
    return {
      schemas: data.schemas && typeof data.schemas === 'object' ? data.schemas : {},
      updatedAt: data.updatedAt || null
    };
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
    branchId: record.branchId ?? record.reservation?.branchId ?? null,
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
    lastSourceEventAt: record.lastSourceEventAt || null,
    robotAgentId: record.robotAgentId || null,
    robotClaimedAt: record.robotClaimedAt || null,
    robotLeaseUntil: record.robotLeaseUntil || null,
    robotCompletedAt: record.robotCompletedAt || null,
    robotResult: record.robotResult && typeof record.robotResult === 'object' ? record.robotResult : null,
    reservation: record.reservation && typeof record.reservation === 'object' ? record.reservation : null
  };
}

function normalizeStatus(status) {
  return [
    'queued',
    'sent_to_ident',
    'failed',
    'ignored',
    'robot_processing',
    'robot_completed',
    'robot_failed'
  ].includes(status) ? status : 'queued';
}

function normalizeAgentId(value) {
  const normalized = String(value || '').trim();
  if (!normalized || normalized.length > 120 || !/^[A-Za-z0-9._:-]+$/.test(normalized)) {
    throw new Error('Invalid agentId');
  }
  return normalized;
}

function cleanAgentText(value, maxLength) {
  return String(value || '').trim().slice(0, maxLength);
}

function cleanAgentDate(value) {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

function normalizeAgentSection(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value)
      .filter(([key, item]) => (
        /^[A-Za-z][A-Za-z0-9_]{0,60}$/.test(key) &&
        !/(password|secret|token|api_?key|credential)/i.test(key) &&
        ['string', 'number', 'boolean'].includes(typeof item)
      ))
      .map(([key, item]) => [key, typeof item === 'string' ? item.slice(0, 500) : item])
  );
}

function normalizeAgentDiagnostics(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw badStorageInput('diagnostics report must be an object');
  }

  const discovery = value.discovery && typeof value.discovery === 'object' && !Array.isArray(value.discovery)
    ? value.discovery
    : {};
  const attempts = Array.isArray(discovery.attempts)
    ? discovery.attempts.slice(-50).map((attempt) => ({
        ...normalizeAgentSection(attempt),
        databases: Array.isArray(attempt?.databases)
          ? attempt.databases.slice(0, 50).map((name) => cleanAgentText(name, 256)).filter(Boolean).join(', ')
          : cleanAgentText(attempt?.databases, 1000)
      }))
    : [];
  const state = value.state && typeof value.state === 'object' && !Array.isArray(value.state)
    ? Object.fromEntries(
        Object.entries(value.state)
          .filter(([key, section]) => /^[A-Za-z][A-Za-z0-9_]{0,60}$/.test(key) && section && typeof section === 'object' && !Array.isArray(section))
          .slice(0, 12)
          .map(([key, section]) => [key, normalizeAgentSection(section)])
      )
    : {};

  return {
    generatedAt: cleanAgentDate(value.generatedAt) || new Date().toISOString(),
    agent: normalizeAgentSection(value.agent),
    sql: normalizeAgentSection(value.sql),
    autostart: normalizeAgentSection(value.autostart),
    state,
    discovery: {
      timestamp: cleanAgentDate(discovery.timestamp),
      result: cleanAgentText(discovery.result, 100),
      configuredServer: cleanAgentText(discovery.configuredServer, 500),
      attempts
    },
    logs: Array.isArray(value.logs)
      ? value.logs.slice(-100).map((line) => redactAgentDiagnosticText(cleanAgentText(line, 2000))).filter(Boolean)
      : []
  };
}

function redactAgentDiagnosticText(value) {
  return String(value || '')
    .replace(/((?:"?(?:password|secret|token|api[_-]?key|credential)"?)\s*[=:]\s*"?)[^\s,;"}]+/gi, '$1[REDACTED]');
}

function normalizeDesiredScheduleMapping(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const doctorsSql = cleanAgentText(value.doctorsSql, 20000);
  const branchesSql = cleanAgentText(value.branchesSql, 20000);
  const intervalsSql = cleanAgentText(value.intervalsSql, 20000);
  const servicesSql = cleanAgentText(value.servicesSql, 20000);
  if (!doctorsSql || !branchesSql || !intervalsSql) return null;
  return {
    doctorsSql,
    branchesSql,
    intervalsSql,
    servicesSql,
    notes: Array.isArray(value.notes)
      ? value.notes.slice(0, 20).map((item) => cleanAgentText(item, 500)).filter(Boolean)
      : []
  };
}

function normalizeDesiredSqlConfiguration(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const dataSource = cleanAgentText(value.dataSource, 500);
  const database = cleanAgentText(value.database, 256);
  if (!dataSource || !database || /[;\r\n]/.test(dataSource) || /[;\r\n]/.test(database)) return null;
  return { dataSource, database };
}

function normalizeDesiredUpdate(value) {
  if (value === null) return null;
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const version = cleanAgentText(value.version, 64);
  const sha256 = cleanAgentText(value.sha256, 64).toUpperCase();
  const size = Number(value.size || 0);
  const downloadPath = cleanAgentText(value.downloadPath, 300);
  if (
    !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version) ||
    !/^[A-F0-9]{64}$/.test(sha256) ||
    !Number.isSafeInteger(size) || size <= 0 ||
    !/^\/api\/agent\/releases\/[^/]+\/download$/.test(downloadPath)
  ) {
    return null;
  }
  return { version, sha256, size, downloadPath, publishedAt: cleanAgentDate(value.publishedAt) };
}

function normalizeAgentSchema(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || !Array.isArray(value.tables)) {
    throw badStorageInput('schema must contain a tables array');
  }
  if (value.tables.length > 5000) {
    throw badStorageInput('schema contains too many tables');
  }

  let columnCount = 0;
  const tables = value.tables.map((table, tableIndex) => {
    if (!table || typeof table !== 'object' || Array.isArray(table) || !Array.isArray(table.columns)) {
      throw badStorageInput(`schema.tables[${tableIndex}] must contain a columns array`);
    }
    if (table.columns.length > 2000) {
      throw badStorageInput(`schema.tables[${tableIndex}] contains too many columns`);
    }
    columnCount += table.columns.length;
    if (columnCount > 100000) {
      throw badStorageInput('schema contains too many columns');
    }
    return {
      schema: cleanAgentText(table.schema, 256),
      name: cleanAgentText(table.name, 256),
      type: cleanAgentText(table.type, 80),
      columns: table.columns.map((column) => ({
        position: optionalFiniteNumber(column?.position),
        name: cleanAgentText(column?.name, 256),
        type: cleanAgentText(column?.type, 128),
        maxLength: optionalFiniteNumber(column?.maxLength),
        precision: optionalFiniteNumber(column?.precision),
        scale: optionalFiniteNumber(column?.scale),
        nullable: column?.nullable === true
      }))
    };
  });

  return {
    generatedAt: cleanAgentDate(value.generatedAt),
    server: cleanAgentText(value.server, 256),
    database: cleanAgentText(value.database, 256),
    summary: {
      tables: tables.length,
      columns: columnCount
    },
    tables
  };
}

function optionalFiniteNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function badStorageInput(message) {
  const error = new Error(message);
  error.status = 400;
  return error;
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
