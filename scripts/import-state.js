import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { loadConfig } from '../src/config.js';
import { createStorage } from '../src/storage.js';
import { TOKEN_STATE_KEY } from './state-keys.js';

const config = loadConfig();
const storage = createStorage(config, console);
const includeSecrets = process.env.STATE_INCLUDE_SECRETS !== 'false';
const inputFile = resolveInputFile(config);
const confirmed = process.env.STATE_IMPORT_CONFIRM === 'YES' || process.argv.includes('--yes');

try {
  if (!inputFile) {
    console.error('Set STATE_IMPORT_FILE or pass a backup file path as the first argument.');
    process.exitCode = 2;
  } else if (!confirmed) {
    console.error('Import overwrites current state. Set STATE_IMPORT_CONFIRM=YES or pass --yes.');
    process.exitCode = 2;
  } else {
    const payload = parseJson(await readFile(inputFile, 'utf8'));
    assertPayload(payload);

    const keys = Object.entries(payload.keys);
    let imported = 0;
    let skipped = 0;

    for (const [key, value] of keys) {
      if (!includeSecrets && key === TOKEN_STATE_KEY) {
        skipped += 1;
        continue;
      }

      if (key === TOKEN_STATE_KEY) await writeTokenState(config, storage, value);
      else await storage.writeJson(key, value);
      imported += 1;
    }

    console.log(`Imported ${imported} state keys from ${inputFile}`);
    if (skipped) console.log(`Skipped ${skipped} secret state keys.`);
  }
} finally {
  storage.close?.();
}

function resolveInputFile(config) {
  if (process.env.STATE_IMPORT_FILE) {
    return path.resolve(config.rootDir, process.env.STATE_IMPORT_FILE);
  }

  const positional = process.argv.slice(2).find((arg) => arg !== '--yes');
  return positional ? path.resolve(config.rootDir, positional) : '';
}

function assertPayload(payload) {
  if (!payload || typeof payload !== 'object') {
    throw new Error('Invalid state file: root object is missing.');
  }
  if (payload.version !== 1) {
    throw new Error(`Unsupported state file version: ${payload.version}`);
  }
  if (!payload.keys || typeof payload.keys !== 'object' || Array.isArray(payload.keys)) {
    throw new Error('Invalid state file: keys object is missing.');
  }
}

async function writeTokenState(config, storage, value) {
  if (config.storage.driver === 'sqlite') {
    await storage.writeJson(TOKEN_STATE_KEY, value);
    return;
  }

  await mkdir(path.dirname(config.amo.tokenFile), { recursive: true });
  const tempPath = `${config.amo.tokenFile}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  await rename(tempPath, config.amo.tokenFile);
}

function parseJson(raw) {
  return JSON.parse(String(raw).replace(/^\uFEFF/, ''));
}
