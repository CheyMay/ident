import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';

export class AmoTokenStore {
  constructor(filePath, initialToken, options = {}) {
    this.filePath = filePath;
    this.initialToken = initialToken;
    this.storage = options.storage || null;
    this.storageKey = options.storageKey || path.basename(filePath);
  }

  async get() {
    if (this.storage) {
      const stored = await this.storage.readJson(this.storageKey, null);
      if (stored) return normalizeToken({ ...this.initialToken, ...stored });
      const legacy = await this.readFileToken(null);
      if (legacy) {
        await this.storage.writeJson(this.storageKey, legacy);
        return normalizeToken({ ...this.initialToken, ...legacy });
      }
      return normalizeToken(this.initialToken);
    }

    const fileToken = await this.readFileToken(this.initialToken);
    return normalizeToken(fileToken);
  }

  async set(token) {
    if (this.storage) {
      await this.storage.writeJson(this.storageKey, token);
      return;
    }

    await mkdir(path.dirname(this.filePath), { recursive: true });
    const tempPath = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(token, null, 2)}\n`, 'utf8');
    await rename(tempPath, this.filePath);
  }

  async readFileToken(fallback) {
    try {
      const raw = await readFile(this.filePath, 'utf8');
      return parseJson(raw);
    } catch (error) {
      if (error.code === 'ENOENT') return fallback;
      throw error;
    }
  }
}

function normalizeToken(token) {
  return {
    ...token,
    accessToken: token.accessToken || token.access_token || '',
    refreshToken: token.refreshToken || token.refresh_token || '',
    expiresAt: token.expiresAt || token.expires_at || 0,
    baseUrl: token.baseUrl || token.base_url || ''
  };
}

function parseJson(raw) {
  return JSON.parse(String(raw).replace(/^\uFEFF/, ''));
}
