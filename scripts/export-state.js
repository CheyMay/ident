import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { loadConfig } from '../src/config.js';
import { createStorage } from '../src/storage.js';
import { STATE_KEYS, TOKEN_STATE_KEY } from './state-keys.js';

const config = loadConfig();
const storage = createStorage(config, console);
const includeSecrets = process.env.STATE_INCLUDE_SECRETS !== 'false';
const outputFile = resolveOutputFile(config);

try {
  const keys = {};

  for (const key of STATE_KEYS) {
    if (!includeSecrets && key === TOKEN_STATE_KEY) continue;

    const value =
      key === TOKEN_STATE_KEY
        ? await readTokenState(config, storage)
        : await storage.readJson(key, undefined);

    if (value !== undefined) keys[key] = value;
  }

  const payload = {
    version: 1,
    createdAt: new Date().toISOString(),
    storageDriver: config.storage.driver,
    includeSecrets,
    keys
  };

  await mkdir(path.dirname(outputFile), { recursive: true });
  await writeFile(outputFile, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

  console.log(`Exported ${Object.keys(keys).length} state keys to ${outputFile}`);
  if (includeSecrets && keys[TOKEN_STATE_KEY]) {
    console.log('Backup includes the amoCRM OAuth token. Store this file as a secret.');
  }
  if (!includeSecrets) {
    console.log('STATE_INCLUDE_SECRETS=false skipped the amoCRM OAuth token.');
  }
} finally {
  storage.close?.();
}

function resolveOutputFile(config) {
  if (process.env.STATE_EXPORT_FILE) {
    return path.resolve(config.rootDir, process.env.STATE_EXPORT_FILE);
  }
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(config.rootDir, 'backups', `state-${timestamp}.json`);
}

async function readTokenState(config, storage) {
  if (config.storage.driver === 'sqlite') {
    return storage.readJson(TOKEN_STATE_KEY, undefined);
  }

  try {
    return parseJson(await readFile(config.amo.tokenFile, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  }
}

function parseJson(raw) {
  return JSON.parse(String(raw).replace(/^\uFEFF/, ''));
}
