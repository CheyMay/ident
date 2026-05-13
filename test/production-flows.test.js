import assert from 'node:assert/strict';
import test from 'node:test';
import { createHmac } from 'node:crypto';
import { buildAmoAuthorizeUrl, verifyDisconnectSignature } from '../src/amocrm/oauth.js';
import { slotToCatalogElement } from '../src/amocrm/timetable-sync.js';
import { extractLeadIdsFromWebhook, parseFormEncoded } from '../src/amocrm/webhooks.js';
import { loadConfig } from '../src/config.js';

test('builds amoCRM OAuth URL with state', () => {
  const config = loadConfig({ AMOCRM_CLIENT_ID: 'client-1' });
  const url = new URL(buildAmoAuthorizeUrl(config, 'state-1', 'post_message'));

  assert.equal(url.origin, 'https://www.amocrm.ru');
  assert.equal(url.pathname, '/oauth');
  assert.equal(url.searchParams.get('client_id'), 'client-1');
  assert.equal(url.searchParams.get('state'), 'state-1');
  assert.equal(url.searchParams.get('mode'), 'post_message');
});

test('verifies amoCRM disconnect signature', () => {
  const config = loadConfig({
    AMOCRM_CLIENT_ID: 'client-1',
    AMOCRM_CLIENT_SECRET: 'secret-1'
  });
  const signature = createHmac('sha256', 'secret-1').update('client-1|123').digest('hex');
  const query = new URLSearchParams({ client_id: 'client-1', account_id: '123', signature });

  assert.equal(verifyDisconnectSignature(query, config), true);
  query.set('signature', 'bad');
  assert.equal(verifyDisconnectSignature(query, config), false);
});

test('parses amoCRM webhook form payload and extracts lead ids', () => {
  const payload = parseFormEncoded(
    'leads%5Badd%5D%5B0%5D%5Bid%5D=101&leads%5Bupdate%5D%5B0%5D%5Bid%5D=102&account%5Bid%5D=55'
  );

  assert.deepEqual(extractLeadIdsFromWebhook(payload), [101, 102]);
});

test('maps IDENT interval to amoCRM catalog element', () => {
  const element = slotToCatalogElement({
    interval: {
      DoctorId: 2129,
      BranchId: 1,
      StartDateTime: '2026-05-12T10:00:00+03:00',
      LengthInMinutes: 60,
      IsBusy: false
    },
    doctor: { Id: 2129, Name: 'Doctor One' },
    branch: { Id: 1, Name: 'Main Branch' },
    fields: {
      start: 10,
      end: 11,
      doctorId: 12,
      doctorName: 13,
      branchId: 14,
      branchName: 15,
      isBusy: 16,
      identKey: 17
    },
    requestId: '1:2129:2026-05-12T10:00:00+03:00'
  });

  assert.equal(element.request_id, '1:2129:2026-05-12T10:00:00+03:00');
  assert.match(element.name, /Doctor One/);
  assert.deepEqual(
    element.custom_fields_values.map((field) => field.field_id),
    [10, 11, 12, 13, 14, 15, 16, 17]
  );
});
