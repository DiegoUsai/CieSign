// Servizio di signaling di CIE Sign (Cloudflare Worker + Durable Objects).
//
// API compatibile con il sottoinsieme del Firebase Realtime Database usato
// da packages/ciesign_link (SignalingClient):
//   GET    /v1/ice.json                    server ICE, con TURN temporanei
//   GET    /v1/r/<stanza>/<o|a>.json       valore attuale
//   GET    ... con Accept: text/event-stream  ascolto (eventi "put")
//   PUT    /v1/r/<stanza>/<o|a>.json       {c: testo cifrato, ts: {".sv":"timestamp"}}
//   DELETE /v1/r/<stanza>.json             cancella la stanza
//
// Ogni stanza è un Durable Object: vive solo in memoria e si cancella da sola
// dopo cinque minuti. Il servizio vede solo nomi casuali e testo cifrato.

const ROOM = /^\/v1\/r\/([A-Za-z0-9_-]{43})(?:\/(o|a))?\.json$/;
const MAX_CIPHERTEXT = 16384;
const ROOM_LIFETIME_MS = 5 * 60 * 1000;

const json = (v, status = 200) =>
  new Response(JSON.stringify(v), { status, headers: { "content-type": "application/json" } });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/v1/ice.json" && request.method === "GET") return ice(env);
    const m = ROOM.exec(url.pathname);
    if (!m) return json({ error: "Permission denied" }, 401);
    const stub = env.ROOMS.get(env.ROOMS.idFromName(m[1]));
    return stub.fetch(request);
  },
};

async function ice(env) {
  if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return json(null);
  const r = await fetch(
    `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
    {
      method: "POST",
      headers: { authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ ttl: 3600 }),
    },
  );
  if (!r.ok) return json(null);
  const body = await r.json();
  // La porta 53 va in timeout senza trickle ICE: la si toglie, come
  // suggerisce la documentazione di Cloudflare.
  for (const s of body.iceServers ?? []) {
    if (Array.isArray(s.urls)) s.urls = s.urls.filter((u) => !u.includes(":53"));
  }
  return json(body);
}

export class Room {
  constructor(state) {
    this.state = state;
    this.slots = {};
    this.watchers = new Set();
  }

  async fetch(request) {
    const m = ROOM.exec(new URL(request.url).pathname);
    const slot = m[2];
    if (request.method === "GET") {
      if ((request.headers.get("accept") ?? "").includes("text/event-stream")) return this.watch(slot);
      return json(this.value(slot));
    }
    if (request.method === "PUT" && slot) {
      const text = await request.text();
      if (text.length > MAX_CIPHERTEXT + 200) return json({ error: "Too large" }, 400);
      let v;
      try {
        v = JSON.parse(text);
      } catch {
        return json({ error: "Invalid data" }, 400);
      }
      if (typeof v?.c !== "string" || v.c.length > MAX_CIPHERTEXT || v?.ts?.[".sv"] !== "timestamp") {
        return json({ error: "Permission denied" }, 401);
      }
      v = { c: v.c, ts: Date.now() };
      this.slots[slot] = v;
      this.notify();
      await this.state.storage.setAlarm(Date.now() + ROOM_LIFETIME_MS);
      return json(v);
    }
    if (request.method === "DELETE") {
      if (slot) delete this.slots[slot];
      else this.slots = {};
      this.notify();
      return json(null);
    }
    return json({ error: "Method not allowed" }, 405);
  }

  value(slot) {
    if (slot) return this.slots[slot] ?? null;
    return Object.keys(this.slots).length ? this.slots : null;
  }

  watch(slot) {
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const enc = new TextEncoder();
    const w = {
      slot,
      send: (v) =>
        writer.write(enc.encode(`event: put\ndata: ${JSON.stringify({ path: "/", data: v })}\n\n`)).catch(() => {
          this.watchers.delete(w);
        }),
    };
    this.watchers.add(w);
    w.send(this.value(slot));
    return new Response(readable, {
      headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
    });
  }

  notify() {
    for (const w of this.watchers) w.send(this.value(w.slot));
  }

  async alarm() {
    this.slots = {};
    this.notify();
  }
}
