export async function parseWebhookBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString('utf8');
  return {
    raw,
    payload: parseFormEncoded(raw)
  };
}

export function parseFormEncoded(raw) {
  const result = {};
  const params = new URLSearchParams(raw);
  for (const [key, value] of params.entries()) {
    setNested(result, keyToPath(key), value);
  }
  return result;
}

export function extractLeadIdsFromWebhook(payload) {
  const leads = payload?.leads;
  if (!leads || typeof leads !== 'object') return [];

  const ids = [];
  for (const eventName of ['add', 'update', 'status']) {
    const eventItems = Object.values(leads[eventName] || {});
    for (const item of eventItems) {
      const id = Number.parseInt(item?.id, 10);
      if (Number.isFinite(id)) ids.push(id);
    }
  }
  return [...new Set(ids)];
}

function keyToPath(key) {
  const path = [];
  const firstBracket = key.indexOf('[');
  if (firstBracket === -1) return [key];

  path.push(key.slice(0, firstBracket));
  const pattern = /\[([^\]]*)\]/g;
  let match;
  while ((match = pattern.exec(key))) {
    path.push(match[1]);
  }
  return path.filter((part) => part !== '');
}

function setNested(target, path, value) {
  let cursor = target;
  for (let index = 0; index < path.length; index += 1) {
    const key = path[index];
    const isLast = index === path.length - 1;
    if (isLast) {
      cursor[key] = value;
      return;
    }
    cursor[key] ||= {};
    cursor = cursor[key];
  }
}
