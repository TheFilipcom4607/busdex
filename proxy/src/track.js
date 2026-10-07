// Live Activities (#42): a phone follows one vehicle that's coming its way, on the Lock Screen
// and in the Dynamic Island, until it reaches the phone's stop, turns off, drops off the feed
// or gets caught. The app can't poll once the phone is locked, so this does it and pushes.
//
//   POST   /v1/track   start following, or a new push token for one already followed
//   DELETE /v1/track   stop (the app caught it, or the activity was dismissed)
//
// The app sends the stretch of route from the vehicle to the phone, so all this does each
// tick is find the vehicle in the feed and place it on that stretch: no routes.json here.
// One Durable Object holds every follow and polls the city once a tick for all of them.

import { DurableObject } from 'cloudflare:workers';
import { decodePolyline, findVehicle, geometry, project } from './trackgeo.js';

const BUNDLE = 'com.filipmanikowski.tabor';
const FEED = 'https://taborapi.thefilip.com/v1/vehicles';
const TICK_MS = 10_000;
const MAX_FOLLOWS = 300;
// Nothing a phone waits on takes this long; it also caps what one forgotten follow costs.
const MAX_MS = 45 * 60_000;
// Gone from the feed (or reporting the same old fix) this long: lost.
const LOST_MS = 4 * 60_000;
// A fix older than this isn't where the vehicle is.
const STALE_FIX_S = 180;
// This far off the stretch, twice running: it has turned off.
const OFF_ROUTE_M = 120;
// This close to your stop counts as there; this far past it, gone by.
const HERE_M = 30;
const PASSED_M = 150;
// Smaller moves than this aren't worth a push.
const MOVE_M = 25;
// Ended activities stay on the Lock Screen this long.
const DISMISS_S = 10 * 60;

/// The feed as the proxy serves it. This object lives wherever Cloudflare put it (Vienna, the
/// first time), and the city drops calls from abroad; the proxy itself runs in Warsaw.
async function feed(type) {
  try {
    const res = await fetch(`${FEED}?type=${type}`, { headers: { 'User-Agent': 'tabor-tracker/1' } });
    return res.ok ? await res.text() : null;
  } catch {
    return null;
  }
}

export async function handleTrack(request, env) {
  return env.TRACKER.get(env.TRACKER.idFromName('all')).fetch(request);
}

export class Tracker extends DurableObject {
  async fetch(request) {
    let body;
    try {
      body = await request.json();
    } catch {
      return json({ result: 'Expected JSON' }, 400);
    }
    if (typeof body?.id !== 'string' || !/^[A-Za-z0-9-]{1,64}$/.test(body.id)) return json({ result: 'Bad id' }, 400);
    const key = `f:${body.id}`;

    if (request.method === 'DELETE') {
      await this.ctx.storage.delete(key);
      return json({ result: 'ok' }, 200);
    }
    if (request.method !== 'POST') return json({ result: 'POST or DELETE only' }, 405);

    const token = String(body.token ?? '');
    if (!/^[0-9a-f]{32,512}$/.test(token)) return json({ result: 'Bad token' }, 400);
    const old = await this.ctx.storage.get(key);
    if (old) {
      // iOS hands out a new token now and then: same follow, new address.
      await this.ctx.storage.put(key, { ...old, token });
      return json({ result: 'ok' }, 200);
    }

    const follow = parseFollow(body, token);
    if (typeof follow === 'string') return json({ result: follow }, 400);
    const count = (await this.ctx.storage.list({ prefix: 'f:', limit: MAX_FOLLOWS })).size;
    if (count >= MAX_FOLLOWS) return json({ result: 'Too many followed' }, 503);
    await this.ctx.storage.put(key, follow);
    // An alarm already due within a tick will do; one further off is a failed alarm's retry,
    // backing off, which would leave this follow waiting.
    const due = await this.ctx.storage.getAlarm();
    if (!due || due > Date.now() + TICK_MS) await this.ctx.storage.setAlarm(Date.now() + 1000);
    return json({ result: 'ok' }, 200);
  }

  async alarm() {
    const follows = await this.ctx.storage.list({ prefix: 'f:' });
    if (follows.size === 0) return;
    // Rescheduled first, so a slow city or a throw doesn't stop the loop.
    await this.ctx.storage.setAlarm(Date.now() + TICK_MS);

    const feeds = {};
    for (const type of new Set([...follows.values()].map((f) => f.type))) {
      feeds[type] = await feed(type);
    }
    const now = Date.now();
    const warsawNow = warsawClock(now);
    for (const [key, f] of follows) {
      let next = f;
      try {
        next = await this.tick(f, feeds[f.type], now, warsawNow);
      } catch (e) {
        // One bad follow mustn't stop the others; it ends on its own time limit.
        console.log(`track ${f.number}: ${e}`);
      }
      if (next) await this.ctx.storage.put(key, next);
      else await this.ctx.storage.delete(key);
    }
  }

  /// One follow, one tick: the follow as it is now, or null when it's over.
  async tick(f, feed, now, warsawNow) {
    if (now - f.started > MAX_MS) return this.end(f, 'ended');

    const row = feed && findVehicle(feed, f.number);
    const fresh = row && (warsawNow - Date.parse(`${String(row.Time).replace(' ', 'T')}Z`)) / 1000 <= STALE_FIX_S;
    if (!fresh) console.log(`track ${f.number}: ${row ? `fix ${row.Time} too old` : 'not in the feed'}`);
    if (!fresh) {
      // A city hiccup leaves everything as it was; only a long silence ends it.
      const missing = f.missingSince ?? now;
      if (now - missing > LOST_MS) return this.end(f, 'lost');
      return { ...f, missingSince: missing };
    }

    const route = geometry(f);
    const window = f.along == null ? [-Infinity, Infinity] : [f.along - 100, f.along + 2500];
    const fit = project(route, [Number(row.Lat), Number(row.Lon)], window);
    if (!fit || fit.offset > OFF_ROUTE_M) {
      console.log(`track ${f.number}: ${fit ? Math.round(fit.offset) : '?'} m off the route`);
      const off = (f.off ?? 0) + 1;
      if (off >= 2) return this.end(f, 'turnedOff');
      return { ...f, off, missingSince: null };
    }
    // GPS wobbles backwards at stops; the vehicle doesn't.
    const along = Math.max(fit.along, f.along ?? -Infinity);
    const distance = f.targetAlong - along;
    if (distance < -PASSED_M) return this.end(f, 'passed', along);

    const state = content(f, along);
    const last = f.sent;
    const changed = !last || last.phase !== state.phase || last.stops !== state.stops || Math.abs(last.distance - state.distance) >= MOVE_M;
    const next = { ...f, along, off: 0, missingSince: null };
    if (!changed) return next;

    const arrived = state.phase === 'here' && last?.phase !== 'here';
    const sent = await this.push(f, {
      aps: {
        timestamp: Math.floor(now / 1000),
        event: 'update',
        'content-state': state,
        'stale-date': Math.floor(now / 1000) + 90,
        ...(arrived ? { alert: arrivalAlert(f) } : {}),
      },
    });
    return sent === 'gone' ? null : { ...next, sent: state };
  }

  async end(f, phase, along = f.along) {
    const now = Math.floor(Date.now() / 1000);
    await this.push(f, {
      aps: {
        timestamp: now,
        event: 'end',
        'content-state': { ...content(f, along ?? f.startAlong ?? 0), phase },
        'dismissal-date': now + DISMISS_S,
      },
    });
    return null;
  }

  async push(f, payload) {
    const host = f.sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
    try {
      const res = await fetch(`https://${host}/3/device/${f.token}`, {
        method: 'POST',
        headers: {
          authorization: `bearer ${await providerToken(this.env)}`,
          'apns-topic': `${BUNDLE}.push-type.liveactivity`,
          'apns-push-type': 'liveactivity',
          'apns-priority': '10',
        },
        body: JSON.stringify(payload),
      });
      if (res.ok) {
        const st = payload.aps['content-state'];
        console.log(`track ${f.number}: ${payload.aps.event} ${st.phase} ${st.distance} m, ${st.stops} stops`);
        return 'ok';
      }
      const text = await res.text();
      console.log(`track ${f.number}: APNs ${res.status} ${text}`);
      // The activity was dismissed, or the app deleted: nobody to tell any more.
      if (res.status === 410 || /BadDeviceToken|ExpiredToken|DeviceTokenNotForTopic/.test(text)) return 'gone';
    } catch (e) {
      console.log(`track ${f.number}: APNs ${e}`);
    }
    return 'failed';
  }
}

// MARK: - Follows

function parseFollow(b, token) {
  if (b.type !== '1' && b.type !== '2') return 'type must be 1 or 2';
  if (!/^\d{1,6}$/.test(String(b.number ?? ''))) return 'Bad number';
  if (typeof b.path !== 'string' || b.path.length < 4 || b.path.length > 40_000) return 'Bad path';
  if (!Array.isArray(b.stops) || b.stops.length > 150) return 'Bad stops';
  const points = decodePolyline(b.path);
  if (points.length < 2) return 'Bad path';
  const route = geometry({ path: b.path });
  const place = (p) => project(route, [Number(p.lat), Number(p.lon)]);
  const target = b.target && place(b.target);
  if (!target) return 'Bad target';
  const stops = b.stops
    .filter((s) => typeof s?.n === 'string' && s.n.length <= 80)
    .map((s) => ({ n: s.n, along: place(s)?.along ?? -1 }))
    .filter((s) => s.along >= 0)
    .sort((x, y) => x.along - y.along);
  return {
    token,
    sandbox: b.sandbox === true,
    lang: b.lang === 'pl' ? 'pl' : 'en',
    type: b.type,
    number: String(b.number),
    path: b.path,
    stops,
    target: typeof b.target.n === 'string' ? b.target.n.slice(0, 80) : null,
    targetAlong: target.along,
    startDistance: Math.max(1, Number(b.distance) || 1),
    started: Date.now(),
    along: null,
    off: 0,
    missingSince: null,
    sent: null,
  };
}

/// What the Live Activity shows; the keys are the Swift ContentState's.
function content(f, along) {
  const distance = Math.round(f.targetAlong - along);
  return {
    phase: distance <= HERE_M ? 'here' : 'coming',
    distance: Math.max(0, distance),
    stops: f.stops.filter((s) => s.along > along + 15 && s.along <= f.targetAlong + 1).length,
    at: f.stops.filter((s) => s.along <= along + 15).at(-1)?.n ?? null,
    progress: Math.min(1, Math.max(0, 1 - distance / f.startDistance)),
  };
}

function arrivalAlert(f) {
  const where = f.target ?? (f.lang === 'pl' ? 'twój przystanek' : 'your stop');
  return f.lang === 'pl'
    ? { title: `#${f.number} jest przy Tobie`, body: `${where} · aparat w dłoń` }
    : { title: `#${f.number} is at your stop`, body: `${where} · get the camera out` };
}

/// Warsaw's wall clock as if it were UTC, to compare with the feed's zoneless times.
function warsawClock(ms) {
  const s = new Intl.DateTimeFormat('sv-SE', {
    timeZone: 'Europe/Warsaw', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).format(new Date(ms));
  return Date.parse(`${s.replace(' ', 'T')}Z`);
}

// MARK: - APNs provider token

let cachedToken = null;

/// A signed JWT for APNs, reused for 40 minutes (Apple wants a new one at least hourly and
/// refuses ones made more often than every 20).
async function providerToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.iat < 40 * 60) return cachedToken.jwt;
  const b64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const enc = (obj) => b64url(new TextEncoder().encode(JSON.stringify(obj)));
  const head = `${enc({ alg: 'ES256', kid: env.APNS_KEY_ID })}.${enc({ iss: env.APNS_TEAM_ID, iat: now })}`;
  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(head));
  cachedToken = { jwt: `${head}.${b64url(sig)}`, iat: now };
  return cachedToken.jwt;
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}
