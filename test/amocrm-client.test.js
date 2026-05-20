import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import test from 'node:test';
import { AmoClient } from '../src/amocrm/client.js';
import { loadConfig } from '../src/config.js';

test('retries amoCRM requests after rate limit response', async () => {
  let requests = 0;
  const server = createServer((req, res) => {
    requests += 1;
    if (requests === 1) {
      res.writeHead(429, { 'Retry-After': '0' });
      res.end(JSON.stringify({ title: 'rate limit' }));
      return;
    }

    const payload = JSON.stringify({ id: 123, name: 'Lead 123' });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload)
    });
    res.end(payload);
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();

  try {
    const config = loadConfig({
      AMOCRM_BASE_URL: `http://127.0.0.1:${port}`,
      AMOCRM_ACCESS_TOKEN: 'token-1',
      AMOCRM_LONG_LIVED_TOKEN: 'true',
      AMOCRM_RATE_LIMIT_MIN_DELAY_MS: '0',
      AMOCRM_RATE_LIMIT_MAX_RETRIES: '1',
      AMOCRM_RATE_LIMIT_RETRY_BASE_DELAY_MS: '1'
    });
    const client = new AmoClient(config, { get: async () => ({ accessToken: 'token-1' }) });

    const lead = await client.getLeadById(123);

    assert.equal(lead.id, 123);
    assert.equal(requests, 2);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  }
});
