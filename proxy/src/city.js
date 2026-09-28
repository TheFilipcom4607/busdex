// Warsaw's live vehicle feed, for the proxy (index.js).

// The city is moving its open data from api.um.warszawa.pl to dane.um.warszawa.pl and will
// switch the old one off. The new one comes first; the old one covers for it until then.
const DANE = 'https://dane.um.warszawa.pl/api/action/get_ztm_lokalizacja_pojazdow';
const OLD = 'https://api.um.warszawa.pl/api/action/busestrams_get/';
const OLD_RESOURCE = 'f2e5503e-927d-4ad3-9500-4ab9e55deb59';
// The city answers in well under a second; when it doesn't, it tends to hang for minutes.
// Two tries of this still finish before the app gives up at 20 s.
const TIMEOUT_MS = 5_000;

// Both return the reply's text, or null if the call failed. fetchCity also says where the
// list sits in it, for callers that let SQLite parse it instead of spending their own CPU.

async function daneText(type, token) {
  if (!token) return null;
  try {
    const res = await fetch(DANE, {
      method: 'POST',
      headers: { Authorization: token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: Number(type) }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    // The new service answers a bad token with a 500, and sends a bare list.
    if (!res.ok) return null;
    const text = await res.text();
    return text.trimStart().startsWith('[') ? text : null;
  } catch {
    return null;
  }
}

async function oldText(type, key) {
  if (!key) return null;
  const url = `${OLD}?resource_id=${OLD_RESOURCE}&type=${type}&apikey=${encodeURIComponent(key)}`;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!res.ok) return null;
    // Errors come back as 200 with a message in `result` instead of the list.
    const text = await res.text();
    return /"result"\s*:\s*\[/.test(text) ? text : null;
  } catch {
    return null;
  }
}

export async function fetchCity(type, env) {
  const dane = await daneText(type, env.DANE_TOKEN);
  if (dane) return { text: dane, path: '$', source: 'dane' };
  const old = await oldText(type, env.UM_KEY);
  return old ? { text: old, path: '$.result', source: 'old' } : null;
}

// The list itself, for the proxy.
export async function fetchDane(type, token) {
  const text = await daneText(type, token);
  return text && parseList(text, (j) => j);
}

export async function fetchOld(type, key) {
  const text = await oldText(type, key);
  return text && parseList(text, (j) => j.result);
}

function parseList(text, pick) {
  try {
    const list = pick(JSON.parse(text));
    return Array.isArray(list) ? list : null;
  } catch {
    return null;
  }
}
