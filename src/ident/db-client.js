import { normalizeIdentDate, parseDateParam } from '../date.js';
import { BadRequestError, normalizeTimeTablePayload } from './contracts.js';

const DEFAULT_MAPPING = {
  doctorsSql: '',
  branchesSql: '',
  intervalsSql: '',
  servicesSql: '',
  notes: [
    'Each SQL must be read-only SELECT/WITH and should alias columns to the expected names.',
    'doctorsSql: Id, Name',
    'branchesSql: Id, Name',
    'intervalsSql: DoctorId, BranchId, StartDateTime, LengthInMinutes, IsBusy',
    'servicesSql (optional): Id, Name, Code, Price, PriceId, PriceGroupId, PriceGroupName, FolderId, FolderName, CategoryId, CategoryName'
  ]
};

const FORBIDDEN_SQL = /\b(insert|update|delete|merge|drop|alter|truncate|create|exec|execute|grant|revoke|backup|restore)\b/i;

export function createIdentDbClient(config, logger = console) {
  return new IdentDbClient(config.identDb, logger);
}

export function isIdentDbReady(config) {
  return Boolean(config.identDb?.enabled && config.identDb.server && config.identDb.database && config.identDb.user);
}

export function defaultIdentDbMapping() {
  return structuredClone(DEFAULT_MAPPING);
}

export function normalizeIdentDbMapping(input = {}) {
  return {
    ...defaultIdentDbMapping(),
    ...pickStrings(input, ['doctorsSql', 'branchesSql', 'intervalsSql', 'servicesSql']),
    notes: Array.isArray(input.notes) ? input.notes.map(String) : DEFAULT_MAPPING.notes
  };
}

export function validateReadOnlySql(sqlText, label = 'SQL') {
  const raw = String(sqlText || '').trim();
  if (!raw) throw new BadRequestError(`${label} is empty`);
  const normalized = stripSqlComments(raw).trim();
  if (!/^(select|with)\b/i.test(normalized)) {
    throw new BadRequestError(`${label} must start with SELECT or WITH`);
  }
  if (normalized.includes(';')) {
    throw new BadRequestError(`${label} must contain one read-only statement without semicolons`);
  }
  if (FORBIDDEN_SQL.test(normalized)) {
    throw new BadRequestError(`${label} contains a forbidden SQL keyword`);
  }
  return raw;
}

export function normalizeTimetableFromIdentDbRows({ doctors = [], branches = [], intervals = [], services = [] }) {
  const normalizedDoctors = doctors.map((row, index) => {
    const id = intValue(row, ['Id', 'DoctorId', 'doctorId', 'doctor_id', 'ID']);
    const name = stringValue(row, ['Name', 'DoctorName', 'doctorName', 'FullName', 'Fio', 'FIO', 'title']);
    if (!Number.isFinite(id)) throw new BadRequestError(`doctors[${index}].Id is missing`);
    if (!name) throw new BadRequestError(`doctors[${index}].Name is missing`);
    return { Id: id, Name: name };
  });

  let normalizedBranches = branches.map((row, index) => {
    const id = intValue(row, ['Id', 'BranchId', 'branchId', 'branch_id', 'ClinicId', 'ID']);
    const name = stringValue(row, ['Name', 'BranchName', 'branchName', 'ClinicName', 'title']);
    if (!Number.isFinite(id)) throw new BadRequestError(`branches[${index}].Id is missing`);
    if (!name) throw new BadRequestError(`branches[${index}].Name is missing`);
    return { Id: id, Name: name };
  });

  if (!normalizedBranches.length && intervals.length) {
    normalizedBranches = [{ Id: 1, Name: 'Основной филиал' }];
  }

  const defaultBranchId = normalizedBranches[0]?.Id || 1;
  const normalizedIntervals = intervals.map((row, index) => {
    const doctorId = intValue(row, ['DoctorId', 'doctorId', 'doctor_id', 'DoctorID']);
    const branchId = intValue(row, ['BranchId', 'branchId', 'branch_id', 'ClinicId', 'ClinicID']) ?? defaultBranchId;
    const start = normalizeIdentDate(valueByKeys(row, ['StartDateTime', 'startDateTime', 'StartAt', 'Start', 'PlanStart', 'DateStart']));
    const end = normalizeIdentDate(valueByKeys(row, ['EndDateTime', 'endDateTime', 'EndAt', 'End', 'PlanEnd', 'DateEnd']));
    const length = intValue(row, ['LengthInMinutes', 'lengthInMinutes', 'DurationMinutes', 'durationMinutes', 'Length', 'Duration']) ??
      minutesBetween(start, end) ??
      60;
    if (!Number.isFinite(doctorId)) throw new BadRequestError(`intervals[${index}].DoctorId is missing`);
    if (!Number.isFinite(branchId)) throw new BadRequestError(`intervals[${index}].BranchId is missing`);
    if (!start) throw new BadRequestError(`intervals[${index}].StartDateTime is missing`);
    if (!Number.isFinite(length) || length <= 0) throw new BadRequestError(`intervals[${index}].LengthInMinutes is invalid`);
    return {
      DoctorId: doctorId,
      BranchId: branchId,
      StartDateTime: start,
      LengthInMinutes: length,
      IsBusy: boolValue(row, ['IsBusy', 'isBusy', 'Busy', 'busy', 'IsOccupied', 'StatusBusy'])
    };
  });

  const normalizedServices = services.map((row) => ({
    Id: valueByKeys(row, ['Id', 'ServiceId', 'ID_ServiceItems']),
    Name: stringValue(row, ['Name', 'ServiceName']),
    Code: stringValue(row, ['Code', 'ServiceCode']),
    Price: numberValue(row, ['Price', 'ServicePrice']),
    PriceId: valueByKeys(row, ['PriceId', 'ID_ServiceItemPrices']),
    PriceGroupId: valueByKeys(row, ['PriceGroupId', 'ID_ServicePriceGroups']),
    PriceGroupName: stringValue(row, ['PriceGroupName']),
    FolderId: valueByKeys(row, ['FolderId', 'ID_ServiceFolders']),
    FolderName: stringValue(row, ['FolderName']),
    CategoryId: valueByKeys(row, ['CategoryId', 'ID_ServiceCategories']),
    CategoryName: stringValue(row, ['CategoryName'])
  }));

  return normalizeTimeTablePayload({
    Doctors: normalizedDoctors,
    Branches: normalizedBranches,
    Intervals: normalizedIntervals,
    Services: normalizedServices
  });
}

export class IdentDbClient {
  constructor(config, logger = console) {
    this.config = config;
    this.logger = logger;
  }

  configured() {
    return Boolean(this.config?.enabled && this.config.server && this.config.database && this.config.user);
  }

  summary() {
    return {
      enabled: Boolean(this.config?.enabled),
      configured: this.configured(),
      driver: this.config?.driver || 'sqlserver',
      server: this.config?.server || null,
      port: this.config?.port || null,
      instanceName: this.config?.instanceName || null,
      database: this.config?.database || null,
      user: this.config?.user || null,
      encrypt: Boolean(this.config?.encrypt),
      trustServerCertificate: Boolean(this.config?.trustServerCertificate)
    };
  }

  async testConnection() {
    this.assertReady();
    return this.withPool(async (pool) => {
      const result = await pool.request().query(`
        SELECT
          CAST(1 AS int) AS ok,
          DB_NAME() AS databaseName,
          @@SERVERNAME AS serverName,
          CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS productVersion
      `);
      const row = result.recordset[0] || {};
      return {
        ok: row.ok === 1,
        databaseName: row.databaseName || this.config.database,
        serverName: row.serverName || this.config.server,
        productVersion: row.productVersion || null,
        checkedAt: new Date().toISOString()
      };
    });
  }

  async getSchema() {
    this.assertReady();
    return this.withPool(async (pool) => {
      const tablesResult = await pool.request().query(`
        SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
        FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_TYPE IN ('BASE TABLE', 'VIEW')
        ORDER BY TABLE_SCHEMA, TABLE_NAME
      `);
      const columnsResult = await pool.request().query(`
        SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, IS_NULLABLE, ORDINAL_POSITION
        FROM INFORMATION_SCHEMA.COLUMNS
        ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
      `);
      const columnsByTable = new Map();
      for (const column of columnsResult.recordset) {
        const key = `${column.TABLE_SCHEMA}.${column.TABLE_NAME}`;
        if (!columnsByTable.has(key)) columnsByTable.set(key, []);
        columnsByTable.get(key).push({
          name: column.COLUMN_NAME,
          type: column.DATA_TYPE,
          nullable: column.IS_NULLABLE === 'YES',
          position: column.ORDINAL_POSITION
        });
      }

      const tables = tablesResult.recordset.map((table) => {
        const key = `${table.TABLE_SCHEMA}.${table.TABLE_NAME}`;
        return {
          schema: table.TABLE_SCHEMA,
          name: table.TABLE_NAME,
          type: table.TABLE_TYPE,
          columns: columnsByTable.get(key) || []
        };
      });

      return {
        receivedAt: new Date().toISOString(),
        summary: {
          tables: tables.length,
          columns: columnsResult.recordset.length
        },
        tables
      };
    });
  }

  async getTableRows({ schema, table, limit }) {
    this.assertReady();
    const cleanSchema = validateIdentifier(schema || 'dbo', 'schema');
    const cleanTable = validateIdentifier(table, 'table');
    const rowLimit = Math.min(Math.max(Number.parseInt(limit || this.config.maxRows, 10) || 50, 1), this.config.maxRows);
    const query = `SELECT TOP (${rowLimit}) * FROM ${quoteIdent(cleanSchema)}.${quoteIdent(cleanTable)}`;
    return this.withPool(async (pool) => {
      const result = await pool.request().query(query);
      return {
        receivedAt: new Date().toISOString(),
        schema: cleanSchema,
        table: cleanTable,
        rows: result.recordset
      };
    });
  }

  async previewTimetable(mapping) {
    this.assertReady();
    const normalized = normalizeIdentDbMapping(mapping);
    const doctorsSql = validateReadOnlySql(normalized.doctorsSql, 'doctorsSql');
    const branchesSql = validateReadOnlySql(normalized.branchesSql, 'branchesSql');
    const intervalsSql = validateReadOnlySql(normalized.intervalsSql, 'intervalsSql');
    const servicesSql = normalized.servicesSql
      ? validateReadOnlySql(normalized.servicesSql, 'servicesSql')
      : '';

    return this.withPool(async (pool) => {
      const doctors = await pool.request().query(doctorsSql);
      const branches = await pool.request().query(branchesSql);
      const intervals = await pool.request().query(intervalsSql);
      const services = servicesSql
        ? await pool.request().query(servicesSql)
        : { recordset: [] };
      const timetable = normalizeTimetableFromIdentDbRows({
        doctors: doctors.recordset,
        branches: branches.recordset,
        intervals: intervals.recordset,
        services: services.recordset
      });
      return {
        mapping: normalized,
        source: 'ident-db',
        timetable
      };
    });
  }

  async withPool(callback) {
    const sql = await loadMssql();
    const pool = new sql.ConnectionPool(buildMssqlConfig(this.config));
    await pool.connect();
    try {
      return await callback(pool, sql);
    } finally {
      await pool.close();
    }
  }

  assertReady() {
    if (!this.config?.enabled) {
      throw new BadRequestError('IDENT DB integration is disabled');
    }
    if (!this.config.server || !this.config.database || !this.config.user) {
      throw new BadRequestError('IDENT DB connection is not fully configured');
    }
  }
}

async function loadMssql() {
  const module = await import('mssql');
  return module.default || module;
}

function buildMssqlConfig(config) {
  const result = {
    user: config.user,
    password: config.password,
    server: config.server,
    database: config.database,
    port: config.port,
    connectionTimeout: config.connectTimeoutMs,
    requestTimeout: config.requestTimeoutMs,
    pool: {
      max: 2,
      min: 0,
      idleTimeoutMillis: 30_000
    },
    options: {
      encrypt: config.encrypt,
      trustServerCertificate: config.trustServerCertificate,
      enableArithAbort: true,
      appName: 'ident-amocrm-integration',
      readOnlyIntent: true
    }
  };
  if (config.instanceName) {
    delete result.port;
    result.options.instanceName = config.instanceName;
  }
  return result;
}

function pickStrings(input, keys) {
  return Object.fromEntries(
    keys
      .map((key) => [key, typeof input[key] === 'string' ? input[key].trim() : ''])
      .filter(([, value]) => value !== '')
  );
}

function stripSqlComments(sqlText) {
  return sqlText
    .replace(/--.*$/gm, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ');
}

function validateIdentifier(value, label) {
  const normalized = String(value || '').trim();
  if (!/^[A-Za-z_][A-Za-z0-9_@$#]*$/.test(normalized)) {
    throw new BadRequestError(`Invalid ${label} identifier`);
  }
  return normalized;
}

function quoteIdent(value) {
  return `[${String(value).replace(/]/g, ']]')}]`;
}

function valueByKeys(row, keys) {
  for (const key of keys) {
    if (row[key] !== undefined && row[key] !== null && row[key] !== '') return row[key];
  }
  return null;
}

function stringValue(row, keys) {
  const value = valueByKeys(row, keys);
  return value === null ? '' : String(value).trim();
}

function intValue(row, keys) {
  const value = valueByKeys(row, keys);
  if (value === null) return null;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function numberValue(row, keys) {
  const value = valueByKeys(row, keys);
  if (value === null) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function boolValue(row, keys) {
  const value = valueByKeys(row, keys);
  if (value === null) return false;
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  return ['1', 'true', 'yes', 'busy', 'занято', 'occupied'].includes(String(value).trim().toLowerCase());
}

function minutesBetween(start, end) {
  const startDate = parseDateParam(start);
  const endDate = parseDateParam(end);
  if (!startDate || !endDate || endDate <= startDate) return null;
  return Math.round((endDate.getTime() - startDate.getTime()) / 60_000);
}
