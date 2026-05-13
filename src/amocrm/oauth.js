import crypto from 'node:crypto';

export class OAuthStateStore {
  constructor(storage) {
    this.storage = storage;
    this.fileName = 'oauth-states.json';
  }

  async create() {
    const state = crypto.randomBytes(24).toString('hex');
    const data = await this.storage.readJson(this.fileName, { states: {} });
    const states = pruneStates(data.states || {});
    states[state] = new Date().toISOString();
    await this.storage.writeJson(this.fileName, { states });
    return state;
  }

  async consume(state) {
    if (!state) return false;
    const data = await this.storage.readJson(this.fileName, { states: {} });
    const states = pruneStates(data.states || {});
    const exists = Boolean(states[state]);
    delete states[state];
    await this.storage.writeJson(this.fileName, { states });
    return exists;
  }
}

export function buildAmoAuthorizeUrl(config, state, mode = 'popup') {
  if (!config.amo.clientId) {
    const error = new Error('AMOCRM_CLIENT_ID is not configured');
    error.status = 500;
    throw error;
  }

  const url = new URL('https://www.amocrm.ru/oauth');
  url.searchParams.set('client_id', config.amo.clientId);
  url.searchParams.set('state', state);
  url.searchParams.set('mode', mode);
  return url.toString();
}

export function verifyDisconnectSignature(query, config) {
  const clientId = query.get('client_id');
  const accountId = query.get('account_id');
  const signature = query.get('signature');

  if (!clientId || !accountId || !signature || !config.amo.clientSecret) return false;
  if (clientId !== config.amo.clientId) return false;

  const expected = crypto
    .createHmac('sha256', config.amo.clientSecret)
    .update(`${clientId}|${Number(accountId)}`)
    .digest('hex');
  if (signature.length !== expected.length) return false;
  return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
}

function pruneStates(states) {
  const threshold = Date.now() - 30 * 60_000;
  return Object.fromEntries(
    Object.entries(states).filter(([, createdAt]) => {
      const time = new Date(createdAt).getTime();
      return Number.isFinite(time) && time >= threshold;
    })
  );
}
