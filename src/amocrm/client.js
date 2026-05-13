export class AmoClient {
  constructor(config, tokenStore, logger = console) {
    this.config = config;
    this.tokenStore = tokenStore;
    this.logger = logger;
  }

  async listLeads({ updatedFrom, updatedTo, limit = 250, offset = 0 } = {}) {
    const requestedLimit = Math.max(1, Number(limit) || 250);
    const pageLimit = Math.min(requestedLimit, 250);
    let page = Math.floor((Number(offset) || 0) / pageLimit) + 1;
    let remaining = requestedLimit;
    const leads = [];

    while (remaining > 0) {
      const pageItems = await this.listLeadsPage({ updatedFrom, updatedTo, limit: Math.min(pageLimit, remaining), page });
      leads.push(...pageItems);
      if (pageItems.length < Math.min(pageLimit, remaining)) break;
      remaining -= pageItems.length;
      page += 1;
    }

    return leads;
  }

  async listLeadsPage({ updatedFrom, updatedTo, limit, page }) {
    const params = new URLSearchParams();
    params.set('with', 'contacts');
    params.set('limit', String(limit));
    params.set('page', String(page));
    params.set('order[updated_at]', 'asc');
    if (updatedFrom) params.set('filter[updated_at][from]', unixSeconds(updatedFrom));
    if (updatedTo) params.set('filter[updated_at][to]', unixSeconds(updatedTo));
    if (this.config.amo.pipelineId) params.set('filter[pipeline_id]', String(this.config.amo.pipelineId));
    if (this.config.amo.statusId) params.set('filter[statuses][0][status_id]', String(this.config.amo.statusId));
    if (this.config.amo.pipelineId && this.config.amo.statusId) {
      params.set('filter[statuses][0][pipeline_id]', String(this.config.amo.pipelineId));
    }

    const response = await this.request(`/api/v4/leads?${params.toString()}`);
    return response?._embedded?.leads || [];
  }

  async getLeadById(id) {
    return this.request(`/api/v4/leads/${id}?with=contacts`);
  }

  async listContactsByIds(ids) {
    const uniqueIds = [...new Set(ids.filter(Boolean).map(Number))];
    if (!uniqueIds.length) return new Map();

    const contacts = new Map();
    for (const chunk of chunks(uniqueIds, 50)) {
      const params = new URLSearchParams();
      params.set('limit', String(chunk.length));
      chunk.forEach((id, index) => params.set(`filter[id][${index}]`, String(id)));
      const response = await this.request(`/api/v4/contacts?${params.toString()}`);
      for (const contact of response?._embedded?.contacts || []) {
        contacts.set(contact.id, contact);
      }
    }
    return contacts;
  }

  async createLeadWithContact(lead) {
    const response = await this.request('/api/v4/leads/complex', {
      method: 'POST',
      body: JSON.stringify([lead])
    });
    return response?._embedded?.leads?.[0] || null;
  }

  async addLeadNote(leadId, text) {
    const response = await this.request(`/api/v4/leads/${leadId}/notes`, {
      method: 'POST',
      body: JSON.stringify([
        {
          note_type: 'common',
          params: { text }
        }
      ])
    });
    return response?._embedded?.notes?.[0] || null;
  }

  async updateLead(leadId, patch) {
    return this.request(`/api/v4/leads/${leadId}`, {
      method: 'PATCH',
      body: JSON.stringify(patch)
    });
  }

  async updateLeadStatus(leadId, statusId, pipelineId = null) {
    const patch = { status_id: Number(statusId) };
    if (pipelineId) patch.pipeline_id = Number(pipelineId);
    return this.updateLead(leadId, patch);
  }

  async upsertWebhook(destination, settings) {
    return this.request('/api/v4/webhooks', {
      method: 'POST',
      body: JSON.stringify({ destination, settings, sort: 10 })
    });
  }

  async listWebhooks(destination) {
    const params = new URLSearchParams();
    if (destination) params.set('filter[destination]', destination);
    const suffix = params.size ? `?${params.toString()}` : '';
    const response = await this.request(`/api/v4/webhooks${suffix}`);
    return response?._embedded?.webhooks || [];
  }

  async listLeadCustomFields() {
    return this.listCollection('/api/v4/leads/custom_fields', 'custom_fields');
  }

  async listPipelines() {
    return this.listCollection('/api/v4/leads/pipelines', 'pipelines');
  }

  async listCatalogs() {
    return this.listCollection('/api/v4/catalogs', 'catalogs');
  }

  async listCatalogCustomFields(catalogId) {
    return this.listCollection(`/api/v4/catalogs/${catalogId}/custom_fields`, 'custom_fields');
  }

  async createCatalogElements(catalogId, elements) {
    if (!elements.length) return [];
    const response = await this.request(`/api/v4/catalogs/${catalogId}/elements`, {
      method: 'POST',
      body: JSON.stringify(elements)
    });
    return response?._embedded?.elements || [];
  }

  async updateCatalogElements(catalogId, elements) {
    if (!elements.length) return [];
    const response = await this.request(`/api/v4/catalogs/${catalogId}/elements`, {
      method: 'PATCH',
      body: JSON.stringify(elements)
    });
    return response?._embedded?.elements || [];
  }

  async exchangeAuthorizationCode({ code, referer }) {
    const { clientId, clientSecret, redirectUri } = this.config.amo;
    if (!clientId || !clientSecret || !redirectUri) {
      throw new AmoError('amoCRM OAuth settings are incomplete', 500);
    }

    const baseUrl = normalizeBaseUrl(referer || this.config.amo.baseUrl);
    if (!baseUrl) throw new AmoError('amoCRM referer/base URL is missing', 400);

    const response = await fetch(`${baseUrl}/oauth2/access_token`, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        client_id: clientId,
        client_secret: clientSecret,
        grant_type: 'authorization_code',
        code,
        redirect_uri: redirectUri
      })
    });

    const data = await parseAmoResponse(response);
    const token = buildStoredToken(data, baseUrl);
    await this.tokenStore.set(token);
    return token;
  }

  async request(path, options = {}) {
    const token = await this.getValidToken();
    const baseUrl = this.resolveBaseUrl(token);
    const response = await fetch(`${baseUrl}${path}`, {
      ...options,
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token.accessToken}`,
        ...(options.headers || {})
      }
    });

    if (response.status === 401 && !this.config.amo.longLivedToken && token.refreshToken) {
      this.logger.warn('amoCRM access token rejected, trying refresh');
      const refreshed = await this.refreshToken(token.refreshToken);
      return this.requestWithAccessToken(path, options, refreshed.accessToken, this.resolveBaseUrl(refreshed));
    }

    return parseAmoResponse(response);
  }

  async requestWithAccessToken(path, options, accessToken, baseUrl) {
    const response = await fetch(`${baseUrl}${path}`, {
      ...options,
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
        ...(options.headers || {})
      }
    });
    return parseAmoResponse(response);
  }

  async getValidToken() {
    const token = await this.tokenStore.get();
    if (!token.accessToken) {
      throw new AmoError('amoCRM access token is not configured', 500);
    }

    if (this.config.amo.longLivedToken) return token;

    const expiresAt = Number(token.expiresAt || 0);
    const refreshToken = token.refreshToken;
    const shouldRefresh = refreshToken && expiresAt && Date.now() > expiresAt - 120_000;
    if (!shouldRefresh) return token;

    return this.refreshToken(refreshToken);
  }

  async refreshToken(refreshToken) {
    const { clientId, clientSecret, redirectUri } = this.config.amo;
    if (!clientId || !clientSecret || !redirectUri) {
      throw new AmoError('amoCRM OAuth refresh settings are incomplete', 500);
    }

    const stored = await this.tokenStore.get();
    const baseUrl = this.resolveBaseUrl(stored);
    const response = await fetch(`${baseUrl}/oauth2/access_token`, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        client_id: clientId,
        client_secret: clientSecret,
        grant_type: 'refresh_token',
        refresh_token: refreshToken,
        redirect_uri: redirectUri
      })
    });

    const data = await parseAmoResponse(response);
    const nextToken = buildStoredToken(data, baseUrl);
    await this.tokenStore.set(nextToken);
    return nextToken;
  }

  resolveBaseUrl(token = {}) {
    const baseUrl = normalizeBaseUrl(this.config.amo.baseUrl || token.baseUrl);
    if (!baseUrl) throw new AmoError('amoCRM base URL is not configured', 500);
    return baseUrl;
  }

  async listCollection(path, embeddedKey, limit = 250) {
    const items = [];
    let page = 1;

    while (page <= 100) {
      const separator = path.includes('?') ? '&' : '?';
      const response = await this.request(`${path}${separator}limit=${limit}&page=${page}`);
      const pageItems = response?._embedded?.[embeddedKey] || [];
      items.push(...pageItems);
      if (pageItems.length < limit) break;
      page += 1;
    }

    return items;
  }
}

export class AmoError extends Error {
  constructor(message, status = 502, details = null) {
    super(message);
    this.name = 'AmoError';
    this.status = status;
    this.details = details;
  }
}

async function parseAmoResponse(response) {
  const text = await response.text();
  const body = text ? safeJson(text) : null;
  if (!response.ok) {
    throw new AmoError(
      body?.detail || body?.title || body?.message || text || `amoCRM HTTP ${response.status}`,
      response.status,
      body
    );
  }
  return body;
}

function safeJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function buildStoredToken(data, baseUrl) {
  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresAt: Date.now() + Number(data.expires_in || 0) * 1000,
    baseUrl
  };
}

function normalizeBaseUrl(value) {
  const trimmed = String(value || '').trim().replace(/\/+$/, '');
  if (!trimmed) return '';
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  return `https://${trimmed}`;
}

function unixSeconds(date) {
  return String(Math.floor(date.getTime() / 1000));
}

function chunks(items, size) {
  const result = [];
  for (let index = 0; index < items.length; index += size) {
    result.push(items.slice(index, index + size));
  }
  return result;
}
