import crypto from 'node:crypto';
import path from 'node:path';
import { inflateRawSync } from 'node:zlib';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';

const REQUIRED_RELEASE_FILES = [
  'release.json',
  'IdentAgent.ps1',
  'IdentWorker.ps1',
  'IdentDesktop.ps1',
  'Apply-IdentAgentUpdate.ps1',
  'Install-IdentAgentTask.ps1'
];

export class AgentReleaseStore {
  constructor(storage, { directory, maxArchiveBytes = 25 * 1024 * 1024 } = {}) {
    this.storage = storage;
    this.directory = path.resolve(directory || './data/agent-releases');
    this.maxArchiveBytes = Math.max(1024, Number(maxArchiveBytes || 0));
    this.fileName = 'agent-releases.json';
    this.publishQueue = Promise.resolve();
  }

  async publish(input = {}) {
    const result = this.publishQueue.then(() => this.publishNow(input));
    this.publishQueue = result.catch(() => {});
    return result;
  }

  async publishNow(input = {}) {
    const version = normalizeReleaseVersion(input.version);
    const existingData = await this.readMetadata();
    if (existingData.releases[version]) {
      const error = new Error('Agent release version already exists');
      error.status = 409;
      throw error;
    }
    const archive = decodeArchive(input.archiveBase64, this.maxArchiveBytes);
    const manifest = inspectReleaseArchive(archive);
    if (manifest.product !== 'code9-ident-agent') {
      throw badReleaseInput('release.json product must be code9-ident-agent');
    }
    if (normalizeReleaseVersion(manifest.version) !== version) {
      throw badReleaseInput('release.json version does not match the published version');
    }

    const sha256 = crypto.createHash('sha256').update(archive).digest('hex').toUpperCase();
    const suppliedHash = String(input.sha256 || '').trim().toUpperCase();
    if (suppliedHash && suppliedHash !== sha256) {
      throw badReleaseInput('Archive SHA-256 does not match');
    }

    await mkdir(this.directory, { recursive: true });
    const archivePath = this.archivePath(version);
    try {
      await writeFile(archivePath, archive, { flag: 'wx' });
    } catch (error) {
      if (error?.code === 'EEXIST') {
        const conflict = new Error('Agent release version already exists');
        conflict.status = 409;
        throw conflict;
      }
      throw error;
    }

    const data = existingData;
    const now = new Date().toISOString();
    const record = {
      version,
      sha256,
      size: archive.length,
      notes: cleanText(input.notes, 2000),
      publishedAt: now,
      downloadPath: `/api/agent/releases/${encodeURIComponent(version)}/download`
    };
    data.releases[version] = record;
    data.updatedAt = now;
    try {
      await this.storage.writeJson(this.fileName, data);
    } catch (error) {
      await rm(archivePath, { force: true });
      throw error;
    }
    return record;
  }

  async list() {
    const data = await this.readMetadata();
    return Object.values(data.releases)
      .map(normalizeReleaseRecord)
      .filter(Boolean)
      .sort((left, right) => String(right.publishedAt).localeCompare(String(left.publishedAt)));
  }

  async get(version) {
    const normalized = normalizeReleaseVersion(version);
    const data = await this.readMetadata();
    return normalizeReleaseRecord(data.releases[normalized]);
  }

  async readArchive(version) {
    const release = await this.get(version);
    if (!release) return null;
    let archive;
    try {
      archive = await readFile(this.archivePath(release.version));
    } catch (error) {
      if (error?.code === 'ENOENT') return null;
      throw error;
    }
    const sha256 = crypto.createHash('sha256').update(archive).digest('hex').toUpperCase();
    if (sha256 !== release.sha256 || archive.length !== release.size) {
      const error = new Error('Stored agent release failed integrity verification');
      error.status = 500;
      throw error;
    }
    return { release, archive };
  }

  archivePath(version) {
    return path.join(this.directory, `ident-desktop-${normalizeReleaseVersion(version)}.zip`);
  }

  async readMetadata() {
    const data = await this.storage.readJson(this.fileName, { releases: {}, updatedAt: null });
    return {
      releases: data.releases && typeof data.releases === 'object' ? data.releases : {},
      updatedAt: data.updatedAt || null
    };
  }
}

export function normalizeReleaseVersion(value) {
  const version = String(value || '').trim();
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version) || version.length > 64) {
    throw badReleaseInput('Invalid release version');
  }
  return version;
}

function decodeArchive(value, maxArchiveBytes) {
  const base64 = String(value || '').replace(/\s+/g, '');
  if (!base64 || !/^[A-Za-z0-9+/]+={0,2}$/.test(base64) || base64.length % 4 !== 0) {
    throw badReleaseInput('archiveBase64 must contain a valid ZIP archive');
  }
  if (base64.length > Math.ceil(maxArchiveBytes / 3) * 4 + 4) {
    throw badReleaseInput(`Agent release exceeds ${maxArchiveBytes} bytes`);
  }
  const archive = Buffer.from(base64, 'base64');
  if (archive.length < 22 || archive.length > maxArchiveBytes || archive.readUInt32LE(0) !== 0x04034b50) {
    throw badReleaseInput('archiveBase64 must contain a valid ZIP archive');
  }
  return archive;
}

function inspectReleaseArchive(archive) {
  const entries = readZipEntries(archive);
  for (const required of REQUIRED_RELEASE_FILES) {
    if (!entries.has(required)) throw badReleaseInput(`Agent release is missing ${required}`);
  }
  const manifestBuffer = extractZipEntry(archive, entries.get('release.json'));
  if (manifestBuffer.length > 64 * 1024) throw badReleaseInput('release.json is too large');
  let manifest;
  try {
    manifest = JSON.parse(manifestBuffer.toString('utf8').replace(/^\uFEFF/, ''));
  } catch {
    throw badReleaseInput('release.json must contain valid JSON');
  }
  if (!Array.isArray(manifest.files) || manifest.files.length === 0 || manifest.files.length > 100) {
    throw badReleaseInput('release.json files must contain update operations');
  }
  for (const item of manifest.files) {
    const source = normalizeZipName(item?.source);
    const destination = normalizeZipName(item?.destination);
    if (!source || !destination || !entries.has(source)) {
      throw badReleaseInput('release.json contains an invalid update operation');
    }
  }
  return manifest;
}

function readZipEntries(archive) {
  const minimum = Math.max(0, archive.length - 65_557);
  let eocd = -1;
  for (let offset = archive.length - 22; offset >= minimum; offset -= 1) {
    if (archive.readUInt32LE(offset) === 0x06054b50) {
      eocd = offset;
      break;
    }
  }
  if (eocd < 0) throw badReleaseInput('ZIP end record was not found');

  const entryCount = archive.readUInt16LE(eocd + 10);
  const centralSize = archive.readUInt32LE(eocd + 12);
  const centralOffset = archive.readUInt32LE(eocd + 16);
  if (entryCount > 1000 || centralOffset + centralSize > archive.length) {
    throw badReleaseInput('ZIP central directory is invalid');
  }

  const entries = new Map();
  let offset = centralOffset;
  for (let index = 0; index < entryCount; index += 1) {
    if (offset + 46 > archive.length || archive.readUInt32LE(offset) !== 0x02014b50) {
      throw badReleaseInput('ZIP central directory is invalid');
    }
    const method = archive.readUInt16LE(offset + 10);
    const compressedSize = archive.readUInt32LE(offset + 20);
    const uncompressedSize = archive.readUInt32LE(offset + 24);
    const nameLength = archive.readUInt16LE(offset + 28);
    const extraLength = archive.readUInt16LE(offset + 30);
    const commentLength = archive.readUInt16LE(offset + 32);
    const localOffset = archive.readUInt32LE(offset + 42);
    const name = normalizeZipName(archive.subarray(offset + 46, offset + 46 + nameLength).toString('utf8'));
    if (!name || name.startsWith('/') || name.includes('../') || name.includes(':')) {
      throw badReleaseInput('ZIP contains an unsafe file path');
    }
    entries.set(name, { method, compressedSize, uncompressedSize, localOffset });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

function extractZipEntry(archive, entry) {
  const offset = entry.localOffset;
  if (offset + 30 > archive.length || archive.readUInt32LE(offset) !== 0x04034b50) {
    throw badReleaseInput('ZIP local entry is invalid');
  }
  const nameLength = archive.readUInt16LE(offset + 26);
  const extraLength = archive.readUInt16LE(offset + 28);
  const start = offset + 30 + nameLength + extraLength;
  const end = start + entry.compressedSize;
  if (end > archive.length) throw badReleaseInput('ZIP entry is truncated');
  const payload = archive.subarray(start, end);
  let result;
  if (entry.method === 0) result = payload;
  else if (entry.method === 8) result = inflateRawSync(payload);
  else throw badReleaseInput('ZIP uses an unsupported compression method');
  if (result.length !== entry.uncompressedSize) throw badReleaseInput('ZIP entry size is invalid');
  return result;
}

function normalizeZipName(value) {
  const result = String(value || '').replace(/\\/g, '/').replace(/^\.\//, '');
  return result.endsWith('/') ? result.slice(0, -1) : result;
}

function normalizeReleaseRecord(value) {
  if (!value || typeof value !== 'object') return null;
  try {
    const version = normalizeReleaseVersion(value.version);
    const sha256 = String(value.sha256 || '').trim().toUpperCase();
    const size = Number(value.size || 0);
    if (!/^[A-F0-9]{64}$/.test(sha256) || !Number.isSafeInteger(size) || size <= 0) return null;
    return {
      version,
      sha256,
      size,
      notes: cleanText(value.notes, 2000),
      publishedAt: value.publishedAt || null,
      downloadPath: `/api/agent/releases/${encodeURIComponent(version)}/download`
    };
  } catch {
    return null;
  }
}

function cleanText(value, maxLength) {
  return String(value || '').trim().slice(0, maxLength);
}

function badReleaseInput(message) {
  const error = new Error(message);
  error.status = 400;
  return error;
}
