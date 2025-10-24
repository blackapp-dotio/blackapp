// functions/index.js
/* eslint-disable no-console */
const admin = require("firebase-admin");
const braintree = require("braintree");
const corsMw = require("cors")({ origin: true });
const functions = require("firebase-functions/v1"); // v1 API (region helper below)
const crypto = require("crypto");
const RSSParser = require("rss-parser");
const sharp = require("sharp");
const { fetch: undiciFetch } = require("undici");
const parser = new RSSParser();

// --- Superadmin override (hardcoded UID)
const SUPERADMIN_UID = "XszTTDbebpcYjiqYqgQPAlxWEs82";


const PLATFORM_FEE_RATE = 0.05; // 5%
const FALLBACK_LOGO = "https://blackapp.io/images/blackapp-logo.png";
const GRAPH_V = "v23.0";

// Prefer global fetch (Node 18+), else lazy import node-fetch
const fetch =
  typeof globalThis.fetch === "function"
    ? globalThis.fetch
    : (...args) => import("node-fetch").then(({ default: f }) => f(...args));

// --- Admin init ---
// Load runtime config FIRST so it can be used by everything else.
const cfg = (() => {
  try { return functions.config(); } catch { return {}; }
})();

const PROJECT_ID =
  process.env.GCLOUD_PROJECT ||
  process.env.GCP_PROJECT ||
  (() => {
    try { return JSON.parse(process.env.FIREBASE_CONFIG || "{}").projectId; } catch { return null; }
  })() ||
  "blackappios";

// Prefer explicit override via env or firebase functions:config:set storage.bucket="your-bucket.appspot.com"
const STORAGE_BUCKET =
  process.env.FIREBASE_STORAGE_BUCKET ||
  (cfg.storage && cfg.storage.bucket) ||
  `${PROJECT_ID}.appspot.com`;

if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.applicationDefault(),
    databaseURL: `https://${PROJECT_ID}-default-rtdb.firebaseio.com`,
    storageBucket: STORAGE_BUCKET,
  });
}


const fn = functions.region("us-central1");
const rtdb = admin.database();
const firestore = admin.firestore();
const db = admin.database();

// Optional: lazy bucket accessor for use inside function bodies.
// (Avoid calling admin.storage().bucket() at module load in case config is missing during analyzer)

function getGcsBucket() { 
return admin.storage().bucket(STORAGE_BUCKET); }


// ---------- Misc helpers ----------

const q = (req, name) => {
  const v = req.query && req.query[name];
  return typeof v === "string" && v.trim() ? v.trim() : undefined;
};
const toISO8601UTC = (d) => new Date(d.toISOString()).toISOString();
const safeNumber = (n) => {
  if (typeof n === "number" && isFinite(n)) return n;
  if (typeof n === "string") {
    const x = Number(n);
    if (isFinite(x)) return x;
  }
  return undefined;
};
const joinAddress = (parts) =>
  parts
    .filter((p) => !!p && String(p).trim() !== "")
    .map((p) => String(p).trim())
    .join(", ");
const logStamp = (tag) => console.log(`🕓 [${new Date().toISOString()}] ${tag}`);

function nightWindow(days = 14) {
  const now = new Date();
  const start = new Date(now);
  start.setHours(0, 0, 0, 0);
  const end = new Date(start.getTime() + Math.max(1, days) * 864e5);
  return { start, end };
}

// Feed utils namespace
const FEED = {
  zISO(d) {
    const dt = d instanceof Date ? d : new Date(d);
    return dt.toISOString().replace(/\.\d{3}Z$/, "Z");
  },
  pickHero(images) {
    if (!Array.isArray(images)) return null;
    const clean = (u) => {
      if (!u || typeof u !== "string") return null;
      let url = u.replace(/^http:/i, "https:");
      const lower = url.toLowerCase();
      if (lower.includes("placeholder") || lower.includes("pixel") || lower.endsWith("/0")) return null;
      return url;
    };
    const norm = images
      .map((img) => ({
        url: clean(img?.url),
        width: Number(img?.width || 0),
        height: Number(img?.height || 0),
        ratio: (img?.ratio || "").toLowerCase(),
      }))
      .filter((i) => !!i.url);

    if (!norm.length) return null;
    const is169ish = (w, h) => {
      if (!w || !h) return false;
      const r = w / h;
      return Math.abs(r - 16 / 9) < 0.08 || Math.abs(r - 3 / 2) < 0.08;
    };
    const preferred = norm
      .filter((i) => (i.ratio === "16_9" || i.ratio === "3_2" || is169ish(i.width, i.height)) && i.width >= 1000)
      .sort((a, b) => b.width - a.width);
    if (preferred.length) return preferred[0].url;
    const largest = norm.sort((a, b) => b.width * b.height - a.width * a.height);
    return largest[0]?.url || null;
  },
};

// Brand/config helpers (single source of truth)
function getMetaUserToken() {
  try { return (functions.config().meta && functions.config().meta.user_access_token) || process.env.META_USER_ACCESS_TOKEN || ""; }
  catch { return process.env.META_USER_ACCESS_TOKEN || ""; }
}
function getMetaPageToken() {
  try { return (functions.config().meta && functions.config().meta.page_access_token) || process.env.META_PAGE_ACCESS_TOKEN || ""; }
  catch { return process.env.META_PAGE_ACCESS_TOKEN || ""; }
}
function getBrandSiteLink() {
  try { return (functions.config().brand && functions.config().brand.site_link) || "https://blackapp.io/"; }
  catch { return "https://blackapp.io/"; }
}
function getLogoFallback() {
  try { return (functions.config().brand && functions.config().brand.logo_fallback) || FALLBACK_LOGO; }
  catch { return FALLBACK_LOGO; }
}

// Convenience: build CF URLs in this project
function cfUrl(name, qs = {}) {
  const base = `https://us-central1-${process.env.GCLOUD_PROJECT || "blackappios"}.cloudfunctions.net/${name}`;
  const u = new URL(base);
  Object.entries(qs).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== "") u.searchParams.set(k, String(v));
  });
  return u.toString();
}



// ---- iOS notification categories used by the app ----
const IOS_CATEGORIES = {
  CHAT: "CHAT_MESSAGE",
  GROUP: "GROUP_MESSAGE",
  EVENT: "EVENT_REMINDER",
};

// Unified iOS helper
function withIOSCategory(base, iosCategory, threadId) {
  const p = {
    ...base,
    ios_category: iosCategory,          // => aps.category
    ios_sound: "default",
    ios_badgeType: "Increase",
    ios_badgeCount: 1,
    mutable_content: true,
    content_available: false,
    ios_interruption_level: "active",
  };
  if (threadId) p.thread_id = threadId;
  return p;
}

// Location normalization for Ticketmaster
function normalizeLocationForTM(address /* e.g. "Charlotte, NC" */) {
  const out = {};
  const cityState = address.match(/^([^,]+),\s*([A-Za-z]{2})$/);
  if (cityState) {
    out.city = cityState[1].trim();
    out.stateCode = cityState[2].toUpperCase();
    out.countryCode = "US";
    return out;
  }
  const stateUSA = address.match(/^([A-Za-z .'-]+),\s*(USA|United States)$/i);
  if (stateUSA) {
    const name = stateUSA[1].trim();
    const map = {
      Alabama:"AL", Alaska:"AK", Arizona:"AZ", Arkansas:"AR", California:"CA", Colorado:"CO",
      Connecticut:"CT", Delaware:"DE", Florida:"FL", Georgia:"GA", Hawaii:"HI", Idaho:"ID",
      Illinois:"IL", Indiana:"IN", Iowa:"IA", Kansas:"KS", Kentucky:"KY", Louisiana:"LA",
      Maine:"ME", Maryland:"MD", Massachusetts:"MA", Michigan:"MI", Minnesota:"MN", Mississippi:"MS",
      Missouri:"MO", Montana:"MT", Nebraska:"NE", Nevada:"NV", "New Hampshire":"NH", "New Jersey":"NJ",
      "New Mexico":"NM", "New York":"NY", "North Carolina":"NC", "North Dakota":"ND", Ohio:"OH",
      Oklahoma:"OK", Oregon:"OR", Pennsylvania:"PA", "Rhode Island":"RI", "South Carolina":"SC",
      "South Dakota":"SD", Tennessee:"TN", Texas:"TX", Utah:"UT", Vermont:"VT", Virginia:"VA",
      Washington:"WA", "West Virginia":"WV", Wisconsin:"WI", Wyoming:"WY"
    };
    const code = map[name];
    if (code) {
      out.stateCode = code;
      out.countryCode = "US";
      return out;
    }
  }
  out.city = address.split(",")[0].trim();
  return out;
}

// ============== Instagram Graph helpers ==============
function gUrl(path, qs = {}) {
  const u = new URL(`https://graph.facebook.com/${GRAPH_V}/${String(path).replace(/^\//, "")}`);
  for (const [k, v] of Object.entries(qs)) if (v !== undefined && v !== null && v !== "") u.searchParams.set(k, String(v));
  return u.toString();
}
async function gGet(path, qs = {}, token) {
  const url = gUrl(path, { ...qs, access_token: token });
  const r = await fetch(url, { method: "GET" });
  if (!r.ok) {
    const body = await r.text().catch(() => "");
    throw new Error(`Graph GET ${url} -> ${r.status} ${body.slice(0, 300)}`);
  }
  return r.json();
}
// Resolve an Instagram User ID from a Facebook Page ID
// Tries both legacy + modern fields returned by the Page node.
async function resolveIgUserId(pageId, token) {
  // Try instagram_business_account first (common on many pages)
  try {
    const a = await gGet(`/${pageId}`, { fields: "instagram_business_account" }, token);
    const idA = a?.instagram_business_account?.id;
    if (idA) return idA;
  } catch (_) {}

  // Fallback to connected_instagram_account (other pages use this)
  try {
    const b = await gGet(`/${pageId}`, { fields: "connected_instagram_account" }, token);
    const idB = b?.connected_instagram_account?.id;
    if (idB) return idB;
  } catch (_) {}

  throw new Error(
    `No IG account linked to Page ${pageId}. Link an Instagram Business/Creator account to the Page first.`
  );
}


// XML helpers (for RSS XML generation)
function xmlEsc(s = "") {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}
function buildIgRss({ title, link, description, items }) {
  const now = new Date().toUTCString();
  const parts = [];
  parts.push(`<?xml version="1.0" encoding="UTF-8"?>`);
  parts.push(`<rss version="2.0">`);
  parts.push(`<channel>`);
  parts.push(`<title>${xmlEsc(title)}</title>`);
  parts.push(`<link>${xmlEsc(link)}</link>`);
  parts.push(`<description>${xmlEsc(description)}</description>`);
  parts.push(`<lastBuildDate>${now}</lastBuildDate>`);
  for (const it of items) {
    parts.push(`<item>`);
    parts.push(`<title>${xmlEsc(it.title || "")}</title>`);
    parts.push(`<link>${xmlEsc(it.permalink || link)}</link>`);
    parts.push(`<guid isPermaLink="true">${xmlEsc(it.permalink || link)}</guid>`);
    parts.push(`<pubDate>${new Date(it.timestamp || Date.now()).toUTCString()}</pubDate>`);
    if (it.image) parts.push(`<enclosure url="${xmlEsc(it.image)}" type="image/jpeg" />`);
    if (it.description) parts.push(`<description><![CDATA[${it.description}]]></description>`);
    parts.push(`</item>`);
  }
  parts.push(`</channel>`);
  parts.push(`</rss>`);
  return parts.join("\n");
}

// Helper: strip HTML tags
function stripHtml(s = "") {
  return String(s).replace(/<[^>]+>/g, "").trim();
}




// === IG media helpers: owned + collab (/tags) ===

// Helper: fetch IG owned media
async function fetchIgMedia(igUserId, token, limit = 25) {
  const fields = "id,caption,media_type,media_url,thumbnail_url,timestamp,permalink";
  const url = `https://graph.facebook.com/${GRAPH_V}/${igUserId}/media?fields=${fields}&limit=${limit}&access_token=${encodeURIComponent(token)}`;
  const r = await fetch(url);
  if (!r.ok) throw new Error(`fetchIgMedia ${igUserId} ${r.status}`);
  const j = await r.json();
  return Array.isArray(j.data) ? j.data : [];
}

// Helper: fetch IG tagged/collab media (requires Public Content Access)
async function fetchIgTagged(igUserId, token, limit = 25) {
  const fields = "id,caption,media_type,media_url,thumbnail_url,timestamp,permalink";
  const url = `https://graph.facebook.com/${GRAPH_V}/${igUserId}/tags?fields=${fields}&limit=${limit}&access_token=${encodeURIComponent(token)}`;
  const r = await fetch(url);
  if (!r.ok) {
    const text = await r.text().catch(() => "");
    if (r.status === 400 && /code\"\s*:\s*10/.test(text)) {
      console.warn(`[IGSYNC] /tags permission missing (Public Content Access). Skipping for ${igUserId}.`);
      return [];
    }
    throw new Error(`fetchIgTagged ${igUserId} ${r.status} ${text}`);
  }
  const j = await r.json();
  return Array.isArray(j.data) ? j.data : [];
}


// Normalize to https and reject obvious garbage
const toHttps = (u) => {
  if (!u) return null;
  try { const url = new URL(String(u)); url.protocol = "https:"; return url.toString(); }
  catch { return null; }
};

// Map IG object → RTDB item (clean raw image + ONE versioned thumb)
function mapIgToItem(m, partnerId) {
  const ts = m?.timestamp ? Date.parse(m.timestamp) : Date.now();
  const title = (m.caption || "").split("\n").shift()?.trim() || "Instagram Post";

  // Choose a raw visual
  //  - for VIDEO: thumbnail_url first (preview image), else media_url (some videos expose a poster)
  //  - for IMAGE/CAROUSEL: media_url first, else thumbnail_url
  const rawCandidate =
    m.media_type === "VIDEO"
      ? (m.thumbnail_url || m.media_url || null)
      : (m.media_url || m.thumbnail_url || null);

  // Unwrap any accidental thumb nesting and force https
  const unwrapped = stripThumb(rawCandidate);
  const rawImage = toHttps(unwrapped || rawCandidate);

  // Build a SINGLE versioned thumb (bump v to invalidate bad caches later)
  const THUMB_VERSION = "2"; // <— bump to invalidate old cached thumbs if needed
  const thumb = cfUrl("imgThumb", {
    url: rawImage || "",
    w: 900,
    // ensure these are always present
    fallback: getLogoFallback(),
    fallbackScale: 0.25,
    v: THUMB_VERSION,
  });

  return {
    id: m.id,
    partnerId,
    title,
    caption: m.caption || "",
    permalink: m.permalink || "",
    mediaType: m.media_type || "",
    // store RAW image only (never an imgThumb)
    image: rawImage,
    rawMediaUrl: m.media_url || null,
    rawThumbUrl: m.thumbnail_url || null,
    // store exactly one thumb we control
    thumb,
    timestamp: ts,
    createdAt: admin.database.ServerValue.TIMESTAMP,
    source: "instagram",
  };
}


// Image resize proxy with 25% centered logo fallback and backend-driven revalidation
exports.imgThumb = fn.https.onRequest(async (req, res) => {
  try {
    const url = String(q(req, "url") || "");
    const fmt = String(q(req, "fmt") || "webp").toLowerCase();
    const w   = Math.max(120, Math.min(Number(q(req, "w")) || 900, 2000));

    const fallbackUrl = String(q(req, "fallback") || getLogoFallback() || FALLBACK_LOGO || "");
    const scale = Math.max(0.05, Math.min(Number(q(req, "fallbackScale")) || 0.25, 0.9));

    const arStr = String(q(req, "ar") || "16:9");
    const [aw, ah] = arStr.includes(":") ? arStr.split(":").map(Number) : [16, 9];
    const h = Math.max(80, Math.round(w * (ah / aw)));
    const bg = String(q(req, "bg") || "transparent");

    const setCT = () => res.set("Content-Type", (fmt === "jpg" || fmt === "jpeg") ? "image/jpeg" : "image/webp");
    // Real images: normal cache + SWR so even if a later request fails, clients can serve cached then revalidate
    const cacheReal = () => res.set("Cache-Control", "public, max-age=86400, s-maxage=86400, stale-while-revalidate=60, stale-if-error=600");
    // Fallbacks: force re-request soon so real image can replace it without app changes
    const cacheFallback = () => res.set("Cache-Control", "no-store, must-revalidate");

    // Hard timeout for upstream to keep UI snappy
    const HARD_MS = 1200;
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), HARD_MS);

    let upstreamBuf = null;
    try {
      if (/^https?:\/\//i.test(url)) {
        const upstream = await undiciFetch(url, { redirect: "follow", signal: ac.signal });
        if (upstream && upstream.ok) upstreamBuf = Buffer.from(await upstream.arrayBuffer());
      }
    } catch (_) {} finally { clearTimeout(t); }

async function renderShrunkFallback() {
  // Always paint a SOLID BLACK canvas for fallbacks (ignore ?bg=)
  const canvas = sharp({
    create: {
      width: w,
      height: h,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 1 }, // <— force black, opaque
    },
  });

  // Try to fetch the fallback logo (still optional)
  let fbBuf = null;
  if (fallbackUrl) {
    try {
      const fbResp = await undiciFetch(fallbackUrl, { redirect: "follow" });
      if (fbResp && fbResp.ok) fbBuf = Buffer.from(await fbResp.arrayBuffer());
    } catch {}
  }

  let out;
  if (fbBuf) {
    const innerW = Math.max(40, Math.round(w * scale)); // ~25% by default
    const logoBuf = await sharp(fbBuf).resize({ width: innerW, withoutEnlargement: true }).toBuffer();
    out = await canvas
      .composite([{ input: logoBuf, gravity: "center" }])
      .toFormat((fmt === "jpg" || fmt === "jpeg") ? "jpeg" : "webp", { quality: 78 })
      .toBuffer();
  } else {
    // No logo available—still return a solid-black tile
    out = await canvas
      .toFormat((fmt === "jpg" || fmt === "jpeg") ? "jpeg" : "webp", { quality: 78 })
      .toBuffer();
  }

  // Fallbacks should NOT cache, so clients will retry for real images
  res.set("Cache-Control", "no-store, must-revalidate");
  res.set("X-Thumb-Status", "fallback");
  res.set("Retry-After", "5");
  res.set("Content-Type", (fmt === "jpg" || fmt === "jpeg") ? "image/jpeg" : "image/webp");
  return res.status(200).send(out);
}


    return await renderShrunkFallback();

  } catch (e) {
    console.error("imgThumb error", e);
    try {
      const w = 900, h = Math.round(900 * 9 / 16);
      const out = await sharp({ create: { width: w, height: h, channels: 4, background: { r:0,g:0,b:0,alpha:0 } } })
        .webp({ quality: 78 }).toBuffer();
      res.set("Content-Type", "image/webp");
      res.set("Cache-Control", "no-store, must-revalidate");
      res.set("X-Thumb-Status", "fallback");
      return res.status(200).send(out);
    } catch {
      return res.status(500).send("thumb error");
    }
  }
});


// DEBUG: list gossip items for a partner (admin-guarded)
// GET /debugGossipItems?key=ADMIN_INIT_KEY&partner=a1loungeclt&limit=20
exports.debugGossipItems = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const key = String(req.query.key || "");
    const adminKey = process.env.ADMIN_INIT_KEY || (functions.config().admin && functions.config().admin.init_key);
    if (!key || key !== adminKey) return res.status(401).json({ error: "unauthorized" });

    const partnerId = String(req.query.partner || "").trim();
    const limit = Math.min(Math.max(parseInt(req.query.limit || "20", 10) || 20, 1), 200);
    if (!partnerId) return res.status(400).json({ error: "Missing ?partner=" });

    // newest-first by timestamp
    const snap = await rtdb.ref(`gossip/items/${partnerId}`)
      .orderByChild("timestamp")
      .limitToLast(limit)
      .get();

    if (!snap.exists()) return res.json({ ok: true, partnerId, count: 0, items: [] });

    const items = [];
    snap.forEach(cs => items.push(cs.val()));
    items.sort((a, b) => (b?.timestamp || 0) - (a?.timestamp || 0));

    // Only return the fields you care about when debugging
    const compact = items.map(m => ({
      id: m.id,
      ts: m.timestamp || m.pubDate || 0,
      title: m.title || m.caption || "Instagram Post",
      permalink: m.permalink || "",
      image: m.image || null,
      thumb: m.thumb || null,
      source: m.source || ""
    }));

    return res.json({ ok: true, partnerId, count: compact.length, items: compact });
  } catch (e) {
    console.error("[debugGossipItems] error:", e);
    return res.status(500).json({ error: String(e?.message || e) });
  }
});




// ---- Hourly sync (owned + collab), newest-first by timestamp
exports.syncInstagramGossip = fn.pubsub
  .schedule("every 60 minutes")
  .onRun(async () => {
    const token = getMetaUserToken?.() || getMetaPageToken?.();
    if (!token) { console.warn("[IGSYNC] No token configured"); return null; }

    const partnersSnap = await rtdb.ref("gossip/partners").get();
    const partners = partnersSnap.exists() ? partnersSnap.val() : {};
    const entries = Object.entries(partners);
    if (!entries.length) { console.log("[IGSYNC] No partners configured"); return null; }

    const updates = {};
    for (const [partnerId, p] of entries) {
      try {
        if (p?.enabled === false) continue;
        let igUserId = String(p?.igUserId || "");
        const pageId = String(p?.pageId || "");

        if (!igUserId && pageId) {
          igUserId = await resolveIgUserId(pageId, token);
          updates[`gossip/partners/${partnerId}/igUserId`] = igUserId;
        }
        if (!igUserId) { console.warn(`[IGSYNC] ${partnerId}: missing igUserId/pageId`); continue; }

        // fetch owned + tagged concurrently
const [owned, tagged] = await Promise.allSettled([
  fetchIgMedia(igUserId, token, 50),
  fetchIgTagged(igUserId, token, 50),
]);

        const mediaOwned  = owned.status  === "fulfilled" ? owned.value  : [];
        const mediaTagged = tagged.status === "fulfilled" ? tagged.value : [];


       console.log(`[IGSYNC] ${partnerId}: /media=${mediaOwned.length} /tags=${mediaTagged.length} (status: owned=${owned.status}, tagged=${tagged.status})`);
if (tagged.status !== "fulfilled") console.warn(`[IGSYNC] ${partnerId}: /tags note → ${(tagged.reason && tagged.reason.message) || String(tagged.reason || "")}`);

// merge + dedupe by id
const seen = new Set();
const merged = [];
for (const m of [...mediaOwned, ...mediaTagged]) {
  if (!m || !m.id || seen.has(m.id)) continue;
  seen.add(m.id);
  const it = mapIgToItem(m, partnerId);
  if (!it.thumb && !it.image) continue;
  merged.push(it);
}

        merged.sort((a, b) => b.timestamp - a.timestamp);

       // NEW: merged count
       console.log(`[IGSYNC] ${partnerId}: merged=${merged.length}`);

        for (const it of merged) {
          updates[`gossip/items/${partnerId}/${it.id}`] = it;
        }
        const newest = merged.length ? merged[0].timestamp : Number(p?.lastSyncTs || 0);
        if (newest && newest !== Number(p?.lastSyncTs || 0)) {
          updates[`gossip/partners/${partnerId}/lastSyncTs`] = newest;
        }

        console.log(`[IGSYNC] ${partnerId}: upsert ${merged.length}, newestTs=${newest || 0}`);
      } catch (e) {
        console.warn(`[IGSYNC] ${partnerId} error:`, e?.message || e);
      }
    }

    if (Object.keys(updates).length) {
      await rtdb.ref().update(updates);
      console.log(`[IGSYNC] Updated ${Object.keys(updates).length} nodes`);
    } else {
      console.log("[IGSYNC] No updates this run");
    }
    return null;
  });

// ---- On-demand sync (owned + collab), supports ?force=1&days=N
exports.syncInstagramNowHttp = fn.https.onRequest(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const partnerId = String((req.query.partner || "")).trim();
    const limit = Math.min(Math.max(parseInt(req.query.limit || "50", 10) || 50, 1), 100);
    const force = String(req.query.force || "") === "1";
    const days  = Math.max(parseInt(req.query.days || "0", 10) || 0, 0);

    if (!partnerId) return res.status(400).json({ error: "Missing ?partner=" });

    const token = getMetaUserToken?.() || getMetaPageToken?.();
    if (!token) return res.status(500).json({ error: "No token configured" });

    const snap = await rtdb.ref(`gossip/partners/${partnerId}`).get();
    if (!snap.exists()) return res.status(404).json({ error: "Unknown partner" });
    const p = snap.val() || {};

    let igUserId = String(p?.igUserId || "");
    const pageId = String(p?.pageId || "");

    if (!igUserId && pageId) {
      igUserId = await resolveIgUserId(pageId, token);
      await rtdb.ref(`gossip/partners/${partnerId}/igUserId`).set(igUserId);
    }
    if (!igUserId) return res.status(400).json({ error: "Partner missing igUserId/pageId" });

    const sinceTs = days ? Date.now() - days * 86400000 : Number(p?.lastSyncTs || 0);

    const [owned, tagged] = await Promise.allSettled([
      fetchIgMedia(igUserId, token, limit),
      fetchIgTagged(igUserId, token, limit),
    ]);

    const ownedList  = owned.status  === "fulfilled" ? owned.value  : [];
    const taggedList = tagged.status === "fulfilled" ? tagged.value : [];

    const updates = {};
    const newItems = [];
    const seen = new Set();

    const pushIfNew = (m) => {
      if (!m || !m.id || seen.has(m.id)) return;
      const ts = m?.timestamp ? Date.parse(m.timestamp) : 0;
      if (!force && sinceTs && ts <= sinceTs) return;
      const it = mapIgToItem(m, partnerId);
      if (!it.thumb && !it.image) return;
      updates[`gossip/items/${partnerId}/${it.id}`] = it;
      newItems.push(it);
      seen.add(m.id);
    };

    [...ownedList, ...taggedList].forEach(pushIfNew);

    const newest = [...ownedList, ...taggedList]
      .reduce((mx, m) => Math.max(mx, m?.timestamp ? Date.parse(m.timestamp) : 0), 0);

    if (newest && (force || newest > Number(p?.lastSyncTs || 0))) {
      updates[`gossip/partners/${partnerId}/lastSyncTs`] = newest;
    }

    if (Object.keys(updates).length) await rtdb.ref().update(updates);

    return res.json({
      ok: true,
      added: newItems.length,
      newestTs: newest || Number(p?.lastSyncTs || 0),
      sinceTs: sinceTs || 0,
      note: (tagged.status === "fulfilled" ? undefined : "tagsSkippedNoPermission"),
    });
  } catch (e) {
    return res.status(500).json({ error: String(e?.message || e) });
  }
});

// Diagnostics: probe a partner's IG connectivity without writing
exports.igPartnerProbe = fn.https.onRequest(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const partnerId = String((req.query.partner || "")).trim();
    const limit = Math.min(Math.max(parseInt(req.query.limit || "10", 10) || 10, 1), 50);
    if (!partnerId) return res.status(400).json({ error: "Missing ?partner=" });

    const token = getMetaUserToken?.() || getMetaPageToken?.();
    if (!token) return res.status(500).json({ error: "No token configured" });

    const ps = await rtdb.ref(`gossip/partners/${partnerId}`).get();
    if (!ps.exists()) return res.status(404).json({ error: "Unknown partner" });
    const p = ps.val() || {};

    let igUserId = String(p?.igUserId || "");
    const pageId = String(p?.pageId || "");
    if (!igUserId && pageId) {
      try { igUserId = await resolveIgUserId(pageId, token); } catch (e) {}
    }

    if (!igUserId) return res.status(400).json({ error: "Partner missing igUserId/pageId" });

    const owned = await fetchIgMedia(igUserId, token, limit).catch(e => ({ _err: e?.message || String(e) }));
    let tagged = [];
    let tagsNote;
    try {
      tagged = await fetchIgTagged(igUserId, token, limit);
    } catch (e) {
      tagged = [];
      tagsNote = e?.message || String(e);
    }

    return res.json({
      ok: true,
      partnerId,
      igUserId,
      tokenKind: getMetaUserToken?.() ? "user_or_app_user" : "page",
      ownedCount: Array.isArray(owned) ? owned.length : 0,
      taggedCount: Array.isArray(tagged) ? tagged.length : 0,
      tagsNote,
      ownedSample: Array.isArray(owned) ? owned.slice(0, 3).map(m => ({ id: m.id, ts: m.timestamp, type: m.media_type })) : [],
      taggedSample: Array.isArray(tagged) ? tagged.slice(0, 3).map(m => ({ id: m.id, ts: m.timestamp, type: m.media_type })) : [],
      errorOwned: !Array.isArray(owned) ? owned : null,
    });
  } catch (e) {
    return res.status(500).json({ error: String(e?.message || e) });
  }
});

// Writer: force-write from /media only (owned posts), no /tags
exports.syncInstagramNowOwnedOnly = fn.https.onRequest(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const partnerId = String((req.query.partner || "")).trim();
    const limit = Math.min(Math.max(parseInt(req.query.limit || "25", 10) || 25, 1), 100);
    if (!partnerId) return res.status(400).json({ error: "Missing ?partner=" });

    const token = getMetaUserToken?.() || getMetaPageToken?.();
    if (!token) return res.status(500).json({ error: "No token configured" });

    const ps = await rtdb.ref(`gossip/partners/${partnerId}`).get();
    if (!ps.exists()) return res.status(404).json({ error: "Unknown partner" });
    const p = ps.val() || {};

    let igUserId = String(p?.igUserId || "");
    const pageId = String(p?.pageId || "");
    if (!igUserId && pageId) {
      igUserId = await resolveIgUserId(pageId, token);
      await rtdb.ref(`gossip/partners/${partnerId}/igUserId`).set(igUserId);
    }
    if (!igUserId) return res.status(400).json({ error: "Partner missing igUserId/pageId" });

    const owned = await fetchIgMedia(igUserId, token, limit);

    const updates = {};
    let added = 0;
    for (const m of owned) {
      const it = mapIgToItem(m, partnerId);
      if (!it.thumb && !it.image) continue;
      updates[`gossip/items/${partnerId}/${it.id}`] = it;
      added++;
    }

    if (added) {
      const newest = owned.reduce((mx, m) => Math.max(mx, m?.timestamp ? Date.parse(m.timestamp) : 0), 0);
      if (newest) updates[`gossip/partners/${partnerId}/lastSyncTs`] = newest;
      await rtdb.ref().update(updates);
    }

    return res.json({ ok: true, partnerId, added, note: "ownedOnly" });
  } catch (e) {
    return res.status(500).json({ error: String(e?.message || e) });
  }
});



// ---- Load ALL IG partner items (no time window), newest-first, image-safe thumbs with 25% logo fallback
async function loadAllPartnerInstagramItems({ thumbWidth = 900, partnerLimit /* optional */ } = {}) {
  // partnerLimit: optional hard cap of total items returned. If omitted, no cap (streams everything).
  const partnersSnap = await db.ref("/gossip/partners").get();
  const partnersObj = partnersSnap.val() || {};

  const enabledPartners = Object.keys(partnersObj).filter(
    (pid) => partnersObj[pid] && partnersObj[pid].enabled !== false
  );
  if (!enabledPartners.length) {
    console.log("[IG] no enabled partners found");
    return [];
  }

  const perPartnerArrays = await Promise.all(
    enabledPartners.map(async (partnerId) => {
      try {
        // ⬇️ No per-partner limit: pull the whole bucket ordered by timestamp
        const ref = db.ref(`/gossip/items/${partnerId}`);
        const snap = await ref.orderByChild("timestamp").get();
        const bucket = [];

        snap.forEach((cs) => {
          const v = cs.val() || {};
          const ts = Number(v.timestamp || v.createdAt || 0);

          // Choose the best raw image candidate we have on record
          const candidates = [v.image, v.rawThumbUrl, v.rawMediaUrl].filter(Boolean);
const forceHttps = (u) => {
  try { const url = new URL(String(u)); url.protocol = "https:"; return url.toString(); }
  catch { return null; }
};
          const rawBest = forceHttps(candidates[0] || null);

          // Always build a thumb that:
          //  - returns logo (25% centered) fast when real image isn’t reachable yet
          //  - swaps to the real image automatically as soon as it’s available
          const safeThumb = cfUrl("imgThumb", {
            url: rawBest || "",
            w: thumbWidth,
            fallback: getLogoFallback(),
            fallbackScale: 0.25,
          });

          // If we have neither thumb nor image candidates, skip the item
          if (!safeThumb && !rawBest) return;

          bucket.push({
            id: String(v.id || cs.key),
            title: String(v.title || v.caption || "Instagram Post"),
            link: String(v.permalink || v.link || ""),
            summary: String(v.caption || v.title || "").slice(0, 800),
            pubDate: ts > 0 ? ts : Date.now(),
            image: rawBest || null,
            thumb: safeThumb || rawBest || null,
            aspect: null,
            kind: "nightlife",              // partner content is nightlife for the client’s 80/20
            source: `instagram:${partnerId}`,
          });
        });

        bucket.sort((a, b) => b.pubDate - a.pubDate);
        console.log("[IG] partner loaded (UNBOUNDED)", {
          partnerId,
          count: bucket.length,
          firstTs: bucket[0]?.pubDate ?? null,
          lastTs: bucket[bucket.length - 1]?.pubDate ?? null,
        });

        return bucket;
      } catch (e) {
        console.warn(`[IG] partner ${partnerId} load error:`, e?.message || e);
        return [];
      }
    })
  );

  // Flatten everything, newest first — no time window, no per-partner cap
  let all = perPartnerArrays.flat().sort((a, b) => b.pubDate - a.pubDate);

  if (Number.isFinite(partnerLimit) && partnerLimit > 0) {
    all = all.slice(0, partnerLimit);
  }

  console.log("[IG] combined items (UNBOUNDED):", all.length, all.slice(0, 3).map((x) => ({
    id: x.id, ts: x.pubDate, src: x.source,
  })));
  return all;
}

// ====== config / helpers ======

// CORS helper (define BEFORE any usage)
const withCors = (handler) => async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type,Authorization");
  if (req.method === "OPTIONS") return res.status(204).send("");
  try { await handler(req, res); } catch (e) {
    console.error("❌ Uncaught handler error:", e);
    res.status(500).json({ error: e.message || "Internal error" });
  }
};


// ====== single Braintree gateway instance ======
const gateway = new braintree.BraintreeGateway({
  environment: braintree.Environment.Sandbox, // switch to Production when ready
  merchantId: "bv3gft4qcdkrznn2",
  publicKey:  "869df6w9p4pks5ch",
  privateKey: "2703c4d9fc5a3e1e9ec7fde9641a2951",
});


// ====================================================================
// A) EVENTS CHECKOUT (unchanged, de-duplicated)
// ====================================================================

exports.generateClientToken = fn.https.onRequest(
  withCors(async (_req, res) => {
    try {
      const { clientToken } = await gateway.clientToken.generate({});
      res.status(200).send({ clientToken });
    } catch (error) {
      console.error("❌ Token generation failed:", error);
      res.status(500).send({ error: "Token generation failed" });
    }
  })
);

exports.createTransaction = fn.https.onRequest(
  withCors(async (req, res) => {
    const {
      paymentMethodNonce,
      userId,
      eventId,
      eventName,
      eventImagePath = "",
      ticketQty = 0,
      ticketPrice = 0,
      tableQty = 0,
      tablePrice = 0,
      eventTime,
    } = req.body || {};

    const ticketQtyNum   = parseInt(ticketQty) || 0;
    const tableQtyNum    = parseInt(tableQty)  || 0;
    const ticketPriceNum = parseFloat(ticketPrice) || 0;
    const tablePriceNum  = parseFloat(tablePrice)  || 0;

    const baseAmount  = +(ticketQtyNum * ticketPriceNum + tableQtyNum * tablePriceNum).toFixed(2);
    const feeAmount   = +(baseAmount * PLATFORM_FEE_RATE).toFixed(2);
    const totalCharge = +(baseAmount + feeAmount).toFixed(2);

    if (!paymentMethodNonce || !userId || !eventId || !eventName) {
      return res.status(400).send({ error: "❌ Missing required fields" });
    }

    let type = "ticket";
    if (ticketQtyNum > 0 && tableQtyNum > 0) type = "mixed";
    else if (tableQtyNum > 0 && ticketQtyNum === 0) type = "table";
    const totalQty = ticketQtyNum + tableQtyNum;

    try {
      const result = await gateway.transaction.sale({
        amount: totalCharge.toFixed(2),
        paymentMethodNonce,
        options: { submitForSettlement: true },
      });
      if (!result.success) throw new Error(result.message || "Transaction unsuccessful");

      const timestamp = Math.floor(Date.now() / 1000);
      const purchaseRef = admin.database().ref(`purchases/${userId}`).push();
      await purchaseRef.set({
        id: purchaseRef.key,
        userId,
        eventId,
        eventTitle: eventName,
        eventImagePath,
        quantity: totalQty,
        type,
        ticketQty: ticketQtyNum,
        ticketPrice: ticketPriceNum,
        tableQty: tableQtyNum,
        tablePrice: tablePriceNum,
        baseAmount,
        platformFee: feeAmount,
        totalAmount: totalCharge,
        timestamp,
        eventTime: eventTime ? parseInt(eventTime) : null,
        paymentMethod: "card",
      });

      res.status(200).send({ success: true, transactionId: result.transaction.id });
    } catch (error) {
      console.error("❌ Transaction failed:", error);
      res.status(500).send({ error: error.message || "Unknown server error" });
    }
  })
);

exports.getPlatformRevenue = fn.https.onRequest(
  withCors(async (_req, res) => {
    try {
      const snapshot = await admin.database().ref("purchases").once("value");

      let totalRevenue = 0;
      let platformEarnings = 0;
      const totalEvents = new Set();
      let ticketsSold = 0;

      snapshot.forEach((userSnap) => {
        userSnap.forEach((purchaseSnap) => {
          const data = purchaseSnap.val();
          const total = parseFloat(data.totalAmount) || 0;
          const fee = parseFloat(data.platformFee) || 0;
          const qty = parseInt(data.ticketQty) || 0;
          const eventId = data.eventId;
          const userId = data.userId;

          if (!userId || !eventId || isNaN(total) || total <= 0) return;
          totalEvents.add(eventId);
          platformEarnings += fee;
          totalRevenue += total;
          ticketsSold += qty;
        });
      });

      res.status(200).send({
        platformEarnings: platformEarnings.toFixed(2),
        totalRevenue: totalRevenue.toFixed(2),
        totalEvents: totalEvents.size,
        ticketsSold,
      });
    } catch (err) {
      console.error("❌ Revenue summary failed:", err);
      res.status(500).send({ error: err.message });
    }
  })
);

exports.getCheckoutURL = fn.https.onRequest(
  withCors((req, res) => {
    const { amount, description } = req.query || {};
    if (!amount || !description) return res.status(400).send({ error: "Missing amount or description" });
    const redirectURL = `https://blackappios.web.app/?amount=${amount}&desc=${encodeURIComponent(description)}`;
    res.status(200).send({ checkoutURL: redirectURL });
  })
);

exports.ping = fn.https.onRequest(
  withCors(async (_req, res) => {
    res.status(200).json({ ok: true, ts: Date.now() });
  })
);


// ====================================================================
// B) BRAND UNIVERSAL CHECKOUT (USD-only for now)
// ====================================================================

// Plain-text client token for hosted page (kept separate name from JSON one above)
exports.client_token = fn.https.onRequest(
  withCors(async (_req, res) => {
    try {
      const { clientToken } = await gateway.clientToken.generate({});
      res.status(200).send(clientToken); // plain text
    } catch (error) {
      console.error("❌ Token generation failed:", error);
      res.status(500).send("Token generation failed");
    }
  })
);

// USD-only charge (no merchantAccountId → default USD account)
exports.charge_braintree = fn.https.onRequest(
  withCors(async (req, res) => {
    try {
      const { nonce, amount, currency = "USD" } = req.body || {};
      const amt = Number(amount);
      const cur = String(currency).toUpperCase();

      if (!nonce || !amt || isNaN(amt) || amt <= 0) {
        return res.status(400).json({ ok: false, error: "Missing or invalid nonce/amount" });
      }
      if (cur !== "USD") {
        return res.status(400).json({ ok: false, errorCode: "UNSUPPORTED_CURRENCY", error: "Only USD is supported" });
      }

      const result = await gateway.transaction.sale({
        amount: amt.toFixed(2),
        paymentMethodNonce: nonce,
        options: { submitForSettlement: true },
      });

      if (!result.success) {
        return res.status(400).json({ ok: false, error: result.message || "Transaction unsuccessful" });
      }

      res.status(200).json({
        ok: true,
        txnId: result.transaction.id,
        paymentType: result.transaction.paymentInstrumentType, // 'credit_card' | 'paypal_account'
      });
    } catch (err) {
      console.error("❌ charge_braintree error:", err);
      res.status(500).json({ ok: false, error: err.message || "Unknown server error" });
    }
  })
);


// GET /gossipRss?partner=a1lounge&limit=30   or  /gossipRss?all=1&limit=50
exports.gossipRss = fn
  .runWith({ timeoutSeconds: 15, memory: "256MB" })
  .https.onRequest(async (req, res) => {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).end();
    }
    res.set("Access-Control-Allow-Origin", "*");

    try {
      const partner = String((req.query.partner || "")).trim();
      const showAll = String(req.query.all || "0") === "1";
      const limit = Math.min(Math.max(parseInt(req.query.limit || "30", 10) || 30, 1), 100);
      const link = getBrandSiteLink();

      const partnersSnap = await rtdb.ref("gossip/partners").get();
      const partners = partnersSnap.exists() ? partnersSnap.val() : {};

      const pickPartners = showAll
        ? Object.entries(partners).filter(([, p]) => p?.enabled !== false).map(([id]) => id)
        : partner ? [partner] : [];

      if (!pickPartners.length) {
        const xml0 = buildIgRss({ title: "Gossip — Instagram", link, description: "No partners", items: [] });
        res.set("Content-Type", "application/rss+xml; charset=UTF-8");
        return res.status(200).send(xml0);
      }

      const allItems = [];
      for (const pid of pickPartners) {
        const itemsSnap = await rtdb.ref(`gossip/items/${pid}`).limitToLast(limit).get();
        if (!itemsSnap.exists()) continue;
        itemsSnap.forEach((child) => allItems.push(child.val()));
      }

      allItems.sort((a, b) => (b?.timestamp || 0) - (a?.timestamp || 0));
      const items = allItems.slice(0, limit).map((m) => ({
  title: m.title || "Instagram Post",
  description: (m.caption || m.summary || "").replace(/\r?\n/g, "<br/>"),
  permalink: m.permalink || m.link || link,
  timestamp: m.timestamp || m.pubDate || Date.now(),
  // For XML only, if there's no image at all we can place logo;
  // but in JSON feeds/UI, keep image null and rely on thumb
  image: m.image ? String(m.image) : getLogoFallback(),
}));


      const title = partner
        ? (partners?.[partner]?.title || `Instagram — ${partner}`)
        : "Gossip — Instagram (All Partners)";

      const xml = buildIgRss({
        title,
        link,
        description: "Cached Instagram posts from partner accounts (via BlackApp).",
        items,
      });

      res.set("Content-Type", "application/rss+xml; charset=UTF-8");
      res.set("Cache-Control", "public, max-age=180, s-maxage=300");
      return res.status(200).send(xml);
    } catch (e) {
      res.set("Content-Type", "text/plain; charset=utf-8");
      return res.status(500).send(`Error: ${e?.message || String(e)}`);
    }
  });

const https = require('https');
const got = require('got');



// ==============================
// X News (Twitter) - #newsBrief
// ==============================
const X_CFG = (() => {
  try {
    const c = functions.config();
    return {
      bearer: (c.x && c.x.bearer) || process.env.X_BEARER || "",
      adminKey: (c.admin && c.admin.init_key) || process.env.ADMIN_INIT_KEY || ""
    };
  } catch {
    return { bearer: process.env.X_BEARER || "", adminKey: process.env.ADMIN_INIT_KEY || "" };
  }
})();

/**
 * Priority order (top → down), one "top" handle per cabinet:
 * AU, Cameroon, Nigeria, Ghana, Kenya, Congo (DRC), South Africa
 * You can override in RTDB at /gossip/xnews/handles (boolean map); the list is
 * re-ordered by this array so the priority is preserved.
 */
const X_PRIORITY_HANDLES = [
  "_AfricanUnion",       // African Union (AU)
  "PRC_Cameroon",        // Cameroon (replace if you prefer a different official)
  "NigeriaGov",          // Nigeria (alt: NGRPresident)
  "GhanaPresidency",     // Ghana (alt: GovtofGhana)
  "StateHouseKenya",     // Kenya (alt: PresidentKE)
  "Presidence_RDC",      // Congo (DRC)
  "PresidencyZA"         // South Africa (alt: GovernmentZA)
];

// --- Store of allowed handles (RTDB): /gossip/xnews/handles/{handle} = true ---
exports.xNewsSetHandles = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const key = String(req.query.key || "");
    if (!key || key !== X_CFG.adminKey) return res.status(401).json({ error: "unauthorized" });

    const body = (req.headers["content-type"] || "").includes("application/json") ? (req.body || {}) : {};
    const handles = Array.isArray(body.handles) ? body.handles : [];
    if (!handles.length) return res.status(400).json({ error: "handles[] required" });

    const updates = {};
    for (const h of handles) {
      const handle = String(h || "").replace(/^@/, "").trim();
      if (!handle) continue;
      updates[`gossip/xnews/handles/${handle}`] = true;
    }
    await rtdb.ref().update(updates);
    return res.json({
      ok: true,
      count: Object.keys(updates).length,
      handles: Object.keys(updates).map(p => p.split("/").pop())
    });
  } catch (e) {
    console.error("xNewsSetHandles error:", e);
    return res.status(500).json({ error: String(e?.message || e) });
  }
});

// --- Internal utils ---
function todayUTC() {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD
}
function dailyUsageRef(handle) {
  return rtdb.ref(`gossip/xnews/usage/${handle}/${todayUTC()}`);
}
function buildLogoThumb(width = 900) {
  // Always render just the brand logo at 25% as the thumb
  return cfUrl("imgThumb", { url: "", w: width, fallback: getLogoFallback(), fallbackScale: 0.25 });
}
function cleanTweetText(t) {
  return String(t || "").replace(/\s+/g, " ").trim();
}
function buildXItem({ id, title, link, pubDate, handle }) {
  return {
    id: id || crypto.createHash("md5").update(`${handle}|${link}|${title}`).digest("hex"),
    title,
    link,
    summary: title,
    pubDate,
    image: null,
    thumb: buildLogoThumb(900),   // <- always 25% logo, per requirement
    aspect: null,
    kind: "news",                 // #newsBrief bucket
    source: `x:@${handle}`
  };
}
function byPriority(handles) {
  const set = new Set(handles.map(h => h.toLowerCase()));
  const ordered = X_PRIORITY_HANDLES.filter(h => set.has(h.toLowerCase()));
  // Append any extra handles that were allowed but not in priority list (if any)
  for (const h of handles) {
    if (!X_PRIORITY_HANDLES.some(p => p.toLowerCase() === h.toLowerCase())) ordered.push(h);
  }
  return ordered;
}

// --- X API helpers ---
function getXBearer() {
  return X_CFG.bearer || "";
}
async function xResolveId(handle, token) {
  const url = new URL(`https://api.twitter.com/2/users/by/username/${encodeURIComponent(handle)}`);
  url.searchParams.set("user.fields", "id,username");
  const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!r.ok) throw new Error(`X API /users/by/username -> ${r.status}`);
  const j = await r.json();
  const id = j?.data?.id;
  if (!id) throw new Error("no user id");
  return id;
}
async function xFetchLatestNonReplyNonRetweet(userId, token, want = 7) {
  // X requires 5..100; we can fetch a few and filter locally.
  const max = Math.max(5, Math.min(25, Number(want) || 7));
  const url = new URL(`https://api.twitter.com/2/users/${userId}/tweets`);
  url.searchParams.set("max_results", String(max));
  url.searchParams.set("tweet.fields", "created_at,referenced_tweets,text");
  // Do NOT rely on exclude=retweets,replies (may not be allowed in all tiers)

  const r = await fetch(url.toString(), { headers: { Authorization: `Bearer ${token}` } });
  if (!r.ok) throw new Error(`/2/users/${userId}/tweets -> ${r.status}`);
  const j = await r.json();
  const arr = Array.isArray(j?.data) ? j.data : [];

  const isRTorReply = (tw) => {
    const refs = Array.isArray(tw?.referenced_tweets) ? tw.referenced_tweets : [];
    return refs.some((x) => x?.type === "retweeted" || x?.type === "replied_to");
  };

  return arr.find((tw) => !isRTorReply(tw)) || null;
}

// --- Nitter RSS fallback (quick and resilient) ---
const NITTER_HOSTS = [
  "https://nitter.net",
  "https://nitter.privacydev.net",
  "https://nitter.poast.org",
  "https://nitter.fdn.fr",
  "https://nitter.mint.lgbt",
  "https://nitter.woodland.cafe"
];

async function fetchNitterRss(handle, abortMs = 3000) {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), abortMs);
  try {
    for (const host of NITTER_HOSTS) {
      const url = `${host}/${encodeURIComponent(handle)}/rss`;
      try {
        const r = await fetch(url, { signal: ac.signal });
        if (!r.ok || !/xml|rss/i.test(r.headers.get("content-type") || "")) continue;
        const xml = await r.text();
        // Parse the first eligible (non RT/reply) item
        const reItem = /<item>([\s\S]*?)<\/item>/g;
        let m;
        while ((m = reItem.exec(xml))) {
          const block = m[1];
          const get = (tag) => {
            const mm = new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`, "i").exec(block);
            return mm ? mm[1] : "";
          };
          const rawTitle = get("title").replace(/<!\[CDATA\[/g, "").replace(/\]\]>/g, "").trim();
          const link = get("link").trim();
          const pub = get("pubDate").trim();
          const ts = pub ? Date.parse(pub) : Date.now();

          // Strip "AccountName: " prefix commonly in Nitter titles
          const title = rawTitle.replace(/^.*?:\s*/, "");

          const isReply = /^@/i.test(title) || /Replying to\s+@/i.test(rawTitle);
          const isRetweet = /^RT\s@/i.test(title) || /Retweeted/i.test(rawTitle);
          if (isReply || isRetweet) continue;

          return { title, link, pubDate: ts };
        }
      } catch { /* try next host */ }
    }
    return null;
  } finally {
    clearTimeout(t);
  }
}

// --- Core: process ONE handle, enforce per-handle cap=1/day ---
async function pullOne(handle) {
  const usageRef = dailyUsageRef(handle);
  const usedSnap = await usageRef.get();
  const used = usedSnap.exists() ? Number(usedSnap.val()) : 0;
  if (used >= 1) return { handle, added: 0, note: "per-handle daily cap reached" };

  // Try official API first
  const token = getXBearer();
  if (token) {
    try {
      const uid = await xResolveId(handle, token);
      const tw = await xFetchLatestNonReplyNonRetweet(uid, token, 7);
      if (tw) {
        const text = cleanTweetText(tw.text);
        if (text) {
          const item = buildXItem({
            id: `x_${tw.id}`,
            title: text,
            link: `https://twitter.com/${handle}/status/${tw.id}`,
            pubDate: tw.created_at ? Date.parse(tw.created_at) : Date.now(),
            handle
          });
          await rtdb.ref(`gossip/xnews/items/${item.id}`).set(item);
          await usageRef.set(used + 1);
          return { handle, added: 1, mode: "x_api", id: item.id };
        }
      }
    } catch (e) {
      const msg = e?.message || String(e);
      const code = (e && e.status) ? e.status : (/\s(\d{3})$/.exec(msg)?.[1] || "");
      console.warn(`[xNews] API fail for @${handle}:`, msg, code ? `(status ${code})` : "");
      if (code && Number(code) !== 429) {
        // hard fail (non-rate-limit) — continue to fallback anyway
      }
    }
  }

  // Fallback via Nitter RSS
  const rss = await fetchNitterRss(handle);
  if (rss) {
    const item = buildXItem({
      id: `xn_${crypto.createHash("md5").update(`${handle}|${rss.link}|${rss.title}`).digest("hex")}`,
      title: rss.title,
      link: rss.link || `https://twitter.com/${handle}`,
      pubDate: rss.pubDate,
      handle
    });
    await rtdb.ref(`gossip/xnews/items/${item.id}`).set(item);
    await usageRef.set(used + 1);
    return { handle, added: 1, mode: "fallback", id: item.id };
  }

  return { handle, added: 0, mode: "none", note: "no eligible tweet found" };
}

// --- Public pull: GET /xNewsPullNow?users=a,b (global cap=3/day; per-handle=1/day) ---
exports.xNewsPullNow = fn.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  try {
    // Build the candidate list
    const usersQS = String(req.query.users || "").trim();
    let handles;
    if (usersQS) {
      handles = usersQS
        .split(",")
        .map(s => s.replace(/^@/, "").trim())
        .filter(Boolean);
    } else {
      const snap = await rtdb.ref("gossip/xnews/handles").get();
      const obj = snap.exists() ? snap.val() : {};
      const fromDb = Object.keys(obj || {});
      handles = fromDb.length ? fromDb : X_PRIORITY_HANDLES;
    }
    // Re-order to priority
    handles = byPriority(handles);

    // Global daily cap
    const GLOBAL_CAP = Math.max(1, Math.min(10, Number(req.query.limit) || 3)); // default 3/day

    const results = [];
    let totalAdded = 0;

    for (const h of handles) {
      if (totalAdded >= GLOBAL_CAP) break;       // stop when the global cap is reached
      const out = await pullOne(h);              // per-handle cap is enforced inside
      results.push(out);
      totalAdded += (out.added || 0);
    }

    return res.json({ ok: true, day: todayUTC(), added: totalAdded, results });
  } catch (e) {
    return res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});

// --- Optional cron: hourly sweep honoring caps (cheap) ---
exports.xNewsCronHourly = fn.pubsub
  .schedule("every 60 minutes")
  .onRun(async () => {
    try {
      const snap = await rtdb.ref("gossip/xnews/handles").get();
      const obj = snap.exists() ? snap.val() : {};
      let handles = Object.keys(obj || {});
      handles = handles.length ? byPriority(handles) : X_PRIORITY_HANDLES;

      let added = 0;
      const GLOBAL_CAP = 3;
      for (const h of handles) {
        if (added >= GLOBAL_CAP) break;
        const out = await pullOne(h);
        added += (out.added || 0);
      }
    } catch (e) {
      console.warn("xNewsCronHourly:", e?.message || e);
    }
    return null;
  });

// ===============================
// Helper: AI Crew → bundle items
// ===============================
async function fetchAICrewPostsForBundle({ limit = 60, thumbWidth = 900 } = {}) {
  try {
    const snap = await rtdb
      .ref("gossip/posts")
      .orderByChild("timestamp")
      .limitToLast(limit) // newest
      .get();

    if (!snap.exists()) return [];

    const out = [];
    snap.forEach((ch) => {
      const it = ch.val() || {};
      if ((it.source || "") !== "ai-scraper") return; // only AI crew
      const id      = it.id || ch.key;
      const title   = it.text || "Untitled";
      const link    = it.eventUrl || it.link || "";
      const image   = it.imageUrl || it.thumb || "";
      const pubDate = Number(it.timestamp || Date.now());
      const kind    = "nightlife";
      const source  = "ai-scraper";

      out.push({
        id,
        title: String(title).slice(0, 200),
        link,
        summary: "", // we don’t have long descriptions from scrapes
        pubDate,
        image: image || null,
        thumb: cfUrl("imgThumb", {
          url: image || "",
          w: thumbWidth,
          fallback: getLogoFallback(),
          fallbackScale: 0.25,
        }),
        aspect: null,
        kind,
        source,
      });
    });

    // newest first
    return out.sort((a, b) => (b.pubDate || 0) - (a.pubDate || 0));
  } catch (e) {
    console.warn("[fetchAICrewPostsForBundle] error:", e?.message || e);
    return [];
  }
}

// ===============================
// Helper: XNews → bundle items
// ===============================
async function fetchXNewsForBundle({ limit = 40, thumbWidth = 900 } = {}) {
  try {
    const snap = await rtdb
      .ref("gossip/xnews/items")
      .orderByChild("pubDate")
      .limitToLast(limit)
      .get();

    if (!snap.exists()) return [];

    const items = [];
    snap.forEach((child) => {
      const it = child.val() || {};
      const id      = it.id || child.key;
      const title   = it.title || it.text || "Untitled";
      const link    = it.link || it.url || "";
      const image   = it.image || it.thumb || "";
      const pubDate = Number(it.pubDate || Date.now());
      const source  = it.source || "xnews";

      items.push({
        id,
        title: String(title).slice(0, 200),
        link,
        summary: it.summary || it.description || "",
        pubDate,
        image: image || null,
        thumb: cfUrl("imgThumb", {
          url: image || "",
          w: thumbWidth,
          fallback: getLogoFallback(),
          fallbackScale: 0.25,
        }),
        aspect: null,
        kind: "news",
        source,
      });
    });

    return items.sort((a, b) => (b.pubDate || 0) - (a.pubDate || 0));
  } catch (e) {
    console.warn("[fetchXNewsForBundle] error:", e?.message || e);
    return [];
  }
}
// ===============================================
// Helper: Build a Cloud Function thumb URL
// (does not rely on any global helpers)
// ===============================================
const PROJECT_ID_FOR_IMGTHUMB =
  process.env.GCLOUD_PROJECT ||
  process.env.GOOGLE_CLOUD_PROJECT ||
  "blackappios";

function buildThumb(url, w = 900) {
  const base = `https://us-central1-${PROJECT_ID_FOR_IMGTHUMB}.cloudfunctions.net/imgThumb`;
  const params = new URLSearchParams({
    url: url || "",
    w: String(w),
    fallback: "https://blackapp.io/images/blackapp-logo.png",
    fallbackScale: "0.25",
  });
  return `${base}?${params.toString()}`;
}

// ===============================================
// Helper: AI-Crew → bundle items (reads /gossip/posts)
// requires rules indexOn: "timestamp" on /gossip/posts (you already added this)
// ===============================================
async function fetchAICrewPostsForBundle({ limit = 50, thumbWidth = 900 } = {}) {
  try {
    // Pull latest posts, then filter to source == 'ai-scraper'
    const snap = await rtdb
      .ref("gossip/posts")
      .orderByChild("timestamp")
      .limitToLast(limit)
      .get();

    if (!snap.exists()) return [];

    const out = [];
    snap.forEach((cs) => {
      const p = cs.val() || {};
      if (p.source !== "ai-scraper") return;

      const id = p.id || cs.key;
      const title = p.text || "Untitled";
      const link = p.eventUrl || p.link || "";
      const image = p.imageUrl || p.image || null;
      const pubDate = Number(p.timestamp || Date.now());
      const author = p.author || "BlackAppCrew";
      const avatar = p.authorAvatarUrl || "https://blackapp.io/images/blackapp-logo.png";

      out.push({
        id,
        title: String(title).slice(0, 200),
        link,
        summary: p.city ? `#${p.city.split(",")[0].trim()}` : "",
        pubDate,
        image,
        thumb: buildThumb(image || "", thumbWidth),
        aspect: null,
        kind: "nightlife",
        source: "ai-scraper",
        author,
        avatar,
        tags: Array.isArray(p.hashTags) ? p.hashTags : [],
        city: p.city || null,
        region: p.region || null,
      });
    });

    // newest first
    return out.sort((a, b) => (b.pubDate || 0) - (a.pubDate || 0));
  } catch (e) {
    console.warn("[fetchAICrewPostsForBundle] error:", e?.message || e);
    return [];
  }
}

// ===============================================
// Helper: XNews → bundle items (reads /gossip/xnews/items)
// Safe: *only* called inside an async handler
// ===============================================
async function fetchXNewsForBundle({ limit = 40, thumbWidth = 900 } = {}) {
  try {
    const snap = await rtdb
      .ref("gossip/xnews/items")
      .orderByChild("pubDate")
      .limitToLast(limit)
      .get();

    if (!snap.exists()) return [];

    const items = [];
    snap.forEach((child) => {
      const it = child.val() || {};
      const id      = it.id || child.key;
      const title   = it.title || it.text || "Untitled";
      const link    = it.link || it.url || "";
      const image   = it.image || it.thumb || "";
      const pubDate = Number(it.pubDate || Date.now());
      const source  = it.source || "xnews";
      const summary = it.summary || it.description || "";

      items.push({
        id,
        title: String(title).slice(0, 200),
        link,
        summary,
        pubDate,
        image: image || null,
        thumb: buildThumb(image || "", thumbWidth),
        aspect: null,
        kind: "news",
        source,
      });
    });

    return items.sort((a, b) => (b.pubDate || 0) - (a.pubDate || 0));
  } catch (e) {
    console.warn("[fetchXNewsForBundle] error:", e?.message || e);
    return [];
  }
}


// Detect a URL that already points to our thumb endpoint
const isThumbUrl = (u) =>
  /cloudfunctions\.net\/imgThumb|blackapp\.io\/api\/imgThumb/i.test(String(u || ""));

// Build a thumb only if it's not already a thumb URL
const thumbFor = (img, givenThumb, w) => {
  const candidate = givenThumb || img || "";
  if (isThumbUrl(candidate)) return candidate;
  return cfUrl("imgThumb", {
    url: candidate,
    w,
    fallback: "https://blackapp.io/images/blackapp-logo.png",
    fallbackScale: 0.25
  });
};


// ===============================
// POST /rssBundle (IG prioritized, resilient, 25% logo fallback, optional cache)
// - Merges: client feeds + Tumblr blogs + AI Crew posts (+ optional xnews cache)
// - Safe await usage (no top-level awaits)
// ===============================
exports.rssBundle = fn
  .runWith({ timeoutSeconds: 20, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    // ---- CORS ----
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type, X-Firebase-AppCheck");
      return res.status(204).end();
    }
    res.set("Access-Control-Allow-Origin", "*");

    // ---- Deadline guard for iOS timeouts ----
    const HARD_DEADLINE_MS = 9000;
    const started = Date.now();
    const timeLeft = () => Math.max(0, HARD_DEADLINE_MS - (Date.now() - started));

    try {
      if (req.method !== "POST") {
        return res.status(405).json({ ok: false, error: "Use POST" });
      }

      // ---------- Parse body ----------
      const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
      const clientFeeds = Array.isArray(body.feeds) ? body.feeds : [];
      const perFeedLimit = Math.min(Math.max(parseInt(body.perFeedLimit || 6, 10) || 6, 1), 30);
      const thumbWidth   = Math.min(Math.max(parseInt(body.thumbWidth   || 900, 10) || 900, 120), 1600);
      const wantCache    = String(body.cache || "1") !== "0";

      // ---------- Helpers ----------
      const normalizeUrl = (u) => {
        try {
          const url = new URL(String(u));
          if (url.protocol === "http:") url.protocol = "https:";
          return url.toString();
        } catch {
          return String(u || "").replace(/^http:/i, "https:");
        }
      };
      const sha1 = (s) => require("crypto").createHash("sha1").update(String(s)).digest("hex");

      // Prefer configured 25% logo if present; fallback to brand/logo path
      const logoFallback =
        (functions.config().meta && functions.config().meta.logo_25) ||
        (functions.config().brand && functions.config().brand.logo_fallback) ||
        "https://blackapp.io/images/blackapp-logo.png";

      const thumbFor = (img) =>
        cfUrl("imgThumb", { url: img || "", w: thumbWidth, fallback: logoFallback, fallbackScale: 0.25 });

      // ---------- Data loaders ----------
      async function fetchAICrewPosts(limit = 60) {
        try {
          const snap = await rtdb.ref("gossip/posts")
            .orderByChild("timestamp")
            .limitToLast(limit)
            .get();

          const rows = [];
          snap.forEach(cs => {
            const v = cs.val() || {};
            if (v.source !== "ai-scraper") return;
            rows.push({
              id: v.id || cs.key,
              title: String(v.text || "Nightlife"),
              link: String(v.eventUrl || v.imageUrl || ""),
              summary: `#${(v.city || "").split(",")[0] || "City"} • by ${v.author || "BlackAppCrew"}`,
              pubDate: Number(v.timestamp || Date.now()),
              image: v.imageUrl || null,
              kind: "nightlife",
              source: "ai-scraper",
              author: v.author || null,
              avatar: v.authorAvatarUrl || logoFallback,
              city: v.city || null,
              region: v.region || null,
              tags: Array.isArray(v.hashTags) ? v.hashTags : []
            });
          });
          rows.sort((a, b) => b.pubDate - a.pubDate);
          return rows;
        } catch (e) {
          console.warn("[rssBundle] AI crew fetch error:", e?.message || e);
          return [];
        }
      }

      async function fetchXNews(limit = 40) {
        try {
          const s = await rtdb.ref("gossip/xnews/items").orderByChild("pubDate").limitToLast(limit).get();
          const arr = [];
          s.forEach(cs => {
            const v = cs.val() || {};
            arr.push({
              id: cs.key,
              title: String(v.title || "Untitled"),
              link: String(v.link || ""),
              summary: String(v.summary || v.description || ""),
              pubDate: Number(v.pubDate || Date.now()),
              image: v.image || null,
              kind: (v.kind === "news" ? "news" : "nightlife"),
              source: String(v.source || "xnews")
            });
          });
          arr.sort((a, b) => b.pubDate - a.pubDate);
          return arr;
        } catch {
          return [];
        }
      }

      async function parseFeed(url, kind, limitPerFeed) {
        try {
          const xml = await fetchXml(url, Math.min(4500, timeLeft()));
          if (!xml || !xml.trim()) return [];
          const parsed = await parser.parseString(xml);
          const items = Array.isArray(parsed.items) ? parsed.items : [];

          const out = [];
          for (const it of items.slice(0, limitPerFeed)) {
            const id = String(it.guid || it.id || it.link || it.title || "").slice(0, 128)
              || sha1(it.link || it.title || Math.random());
            const title = String(
              it.title || it["media:title"] || it["content:encoded:title"] || "Untitled"
            ).slice(0, 200);

            const link = String(it.link || it.guid || "");
            const pubRaw = it.isoDate || it.pubDate || it.published || it.updated || new Date().toISOString();
            const pubDate = Date.parse(pubRaw) || Date.now();

            // Try enclosure/media, else first <img> in content
            let image = it.enclosure?.url || it["media:content"]?.url || it["media:thumbnail"]?.url || null;
            if (!image) {
              const html = (it["content:encoded"] || it["content"] || it["summary"] || it["description"] || "");
              const m = String(html || "").match(/<img[^>]+src="([^"]+)"/i);
              if (m && m[1]) image = m[1];
            }

            const summary = String(
              it.summary || it.contentSnippet || it.description || ""
            ).replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();

            out.push({
              id, title, link, summary,
              pubDate,
              image: image || null,
              kind,
              source: (() => {
                try { return new URL(link).hostname.replace(/^www\./, ""); } catch { return ""; }
              })()
            });
          }
          return out;
        } catch (e) {
          console.warn("[rssBundle] parseFeed failed:", url, e?.message || e);
          return [];
        }
      }

      // ---------- IG partner items ----------
      let igItems = [];
      try {
        igItems = await loadAllPartnerInstagramItems({ thumbWidth });
      } catch (e) {
        console.warn("[rssBundle] IG load error:", e?.message || e);
      }

      // ---------- Merge feed list (client + Tumblr) ----------
      const dedupFeeds = new Set();
      const mergedFeeds = [];

      for (const f of clientFeeds) {
        if (!f || !f.url) continue;
        const kind = (f.kind === "news" ? "news" : "nightlife");
        const url  = normalizeUrl(f.url);
        const key  = `${kind}|${url}`;
        if (dedupFeeds.has(key)) continue;
        dedupFeeds.add(key);
        mergedFeeds.push({ url, kind });
      }

      try {
        const tbSnap = await rtdb.ref("gossip/tumblrBlogs").get();
        const blogs = tbSnap.exists() ? tbSnap.val() : {};
        for (const [, b] of Object.entries(blogs)) {
          if (!b || b.enabled === false || typeof b.url !== "string") continue;
          let u = String(b.url).trim();
          if (!/\/rss$/i.test(u)) u = u.replace(/\/+$/,"") + "/rss";
          u = normalizeUrl(u);
          const key = `nightlife|${u}`;
          if (dedupFeeds.has(key)) continue;
          dedupFeeds.add(key);
          mergedFeeds.push({ url: u, kind: "nightlife" });
        }
      } catch (e) {
        console.warn("[rssBundle] Tumblr load skipped:", e?.message || e);
      }

      // ---------- Fetch everything in parallel ----------
      const rssGroups = await Promise.all(
        mergedFeeds.map(f => parseFeed(f.url, f.kind, perFeedLimit))
      );
      const rssItems = rssGroups.flat();

      const [aiCrew, xnews] = await Promise.all([
        fetchAICrewPosts(60),
        fetchXNews(40)
      ]);

      // ---------- Normalize & guarantee thumbs ----------
      const ensureThumb = (img) => thumbFor(img || ""); // always returns URL with logo fallback

 const igNorm = (Array.isArray(igItems) ? igItems : []).map((it) => ({
  id: it.id || sha1(it.link || it.image || Math.random()),
  title: String(it.title || it.caption || "Nightlife"),
  link: String(it.link || ""),
  summary: String(it.summary || it.caption || "").slice(0, 400),
  pubDate: Number(it.pubDate || it.timestamp || Date.now()),
  image: it.image || null,
  kind: "nightlife",
  source: String(it.source || "instagram"),
  thumb: thumbFor(it.image, it.thumb, thumbWidth)   // <— don’t re-wrap if already a thumb
}));

const aiNorm = aiCrew.map((it) => ({
  ...it,
  thumb: thumbFor(it.image, it.thumb, thumbWidth)
}));

const rssNorm = rssItems.map((it) => ({
  ...it,
  thumb: thumbFor(it.image, it.thumb, thumbWidth)
}));

const xNorm = (xnews || []).map((it) => ({
  ...it,
  thumb: thumbFor(it.image, it.thumb, thumbWidth)
}));

// Unwrap nested imgThumb?url=... chains to the original source (max 3 levels)
const stripThumb = (u) => {
  let s = String(u || "");
  const re = /(cloudfunctions\.net\/imgThumb|blackapp\.io\/api\/imgThumb)/i;
  let guard = 0;
  while (re.test(s) && guard < 3) {
    try {
      const urlObj = new URL(s);
      s = urlObj.searchParams.get("url") || "";
    } catch {
      break;
    }
    guard++;
  }
  return s || null;
};



      // ---------- Merge, filter, de-dupe ----------
      // Filter: require a usable thumb URL (the fallback logo URL also counts)
      const mergedAll = [...aiNorm, ...igNorm, ...rssNorm, ...xNorm].filter(x => !!x.thumb);

      // Global de-dupe by stable key (prefer link, else id, else title|pubDate)
      const seen = new Set();
      const uniq = [];
      for (const it of mergedAll) {
        const key = (it.link && it.link.toLowerCase())
          || (it.id && `id:${it.id}`)
          || sha1(`${it.title}|${it.pubDate}|${it.source}`);
        if (seen.has(key)) continue;
        seen.add(key);
        uniq.push(it);
      }

      // ---------- Sort: IG partners first, then newest ----------
      uniq.sort((a, b) => {
        const aIG = typeof a.source === "string" && a.source.startsWith("instagram");
        const bIG = typeof b.source === "string" && b.source.startsWith("instagram");
        if (aIG !== bIG) return aIG ? -1 : 1;        // IG first
        return (b.pubDate || 0) - (a.pubDate || 0);  // newest next
      });

      // ---------- Optional cache write (fire-and-forget) ----------
      if (wantCache && timeLeft() > 500) {
        try {
          const cacheKey = "latest";
          rtdb.ref(`gossip/rssCache/${cacheKey}`).set({
            ts: Date.now(),
            items: uniq.slice(0, 120)
          }).catch((e) => {
            console.warn("[rssBundle] cache write (items) skipped:", e?.message || e);
          });

          rtdb.ref("gossip/rssCache/latestMeta").set({
            ts: Date.now(),
            counts: {
              ai: aiNorm.length,
              ig: igNorm.length,
              rss: rssNorm.length,
              x: xNorm.length
            }
          }).catch((e) => {
            console.warn("[rssBundle] cache write (meta) skipped:", e?.message || e);
          });
        } catch (e) {
          console.warn("[rssBundle] cache block skipped:", e?.message || e);
        }
      }

      // ---------- Respond ----------
      return res.status(200).json({
        ok: true,
        items: uniq.slice(0, 120)
      });
    } catch (e) {
      console.warn("[rssBundle] fatal:", e?.message || e);
      // best-effort cached response
      try {
        const snap = await rtdb.ref("gossip/rssCache/latest").get();
        if (snap.exists()) {
          const cached = snap.val() || {};
          return res.status(200).json({
            ok: true,
            items: Array.isArray(cached.items) ? cached.items : [],
            cached: true
          });
        }
      } catch {}
      return res.status(200).json({ ok: false, items: [] });
    }
  });



exports.feedTicketmaster = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  // ---- Local helpers (no globals) ----
  const Q = (k) => (req.query && req.query[k]) || (req.body && req.body[k]) || null;
  const toISO8601UTC = (d) => new Date(d).toISOString().replace(/\.\d{3}Z$/, "Z");
  const nightWindow = (days = 14) => {
    const start = new Date(); start.setUTCHours(0,0,0,0);
    const end = new Date(start); end.setUTCDate(end.getUTCDate() + days); end.setUTCHours(23,59,59,999);
    return { start, end };
  };
  const joinAddress = (parts) => parts.filter(Boolean).join(", ");
  const pickHero = (arr) => {
    if (!Array.isArray(arr)) return null;
    // Prefer ~16:9-ish and medium-large sizes if TM provides multiple
    const scored = arr.map(i => {
      const w = i.width || 0, h = i.height || 0;
      const ratio = h ? w / h : 1.78;
      const rScore = 1 - Math.min(1, Math.abs(ratio - 1.78)); // favor 16:9
      const sScore = Math.min(1, (w*h) / (1200*675));
      return { url: i.url, score: rScore*0.6 + sScore*0.4 };
    }).sort((a,b) => b.score - a.score);
    const u = scored[0]?.url || null;
    return typeof u === "string" ? u.replace(/^http:/i, "https:") : null;
  };
  const safeNumber = (x) => {
    const n = Number(x);
    return Number.isFinite(n) ? n : null;
  };
  const normalizeLocationForTM = (cityRaw) => {
    const s = String(cityRaw || "").trim();
    // Best-effort split "City, ST|State|Country"
    const [city, region] = s.split(/\s*,\s*/);
    const out = {};
    if (city) out.city = city;
    if (region) {
      if (region.length === 2) out.stateCode = region.toUpperCase();
      else out.stateCode = region;
    }
    // Country fallback is US if state provided; leave undefined otherwise
    if (out.stateCode && !out.countryCode) out.countryCode = "US";
    return out;
  };

  // ---- Config: read from functions:config() or env ----
  let TM_API_KEY = "";
  try {
    const c = functions.config();
    TM_API_KEY = (c.tm && c.tm.key) || process.env.TM_API_KEY || "";
  } catch {
    TM_API_KEY = process.env.TM_API_KEY || "";
  }

  const debug = String(Q("debug") || "0") === "1";
  const rid = Math.random().toString(36).slice(2, 8);
  const { start, end } = nightWindow(14);
  const cityRaw = Q("city");

  console.log(`🎫 [TM][${rid}] city=${cityRaw} start=${toISO8601UTC(start)} end=${toISO8601UTC(end)}`);

  if (!TM_API_KEY) {
    console.warn(`🎫 [TM][${rid}] TM_API_KEY missing → []`);
    return res.json(debug ? [{ _debug: [{ error: "TM key missing" }] }] : []);
  }

  const loc = cityRaw ? normalizeLocationForTM(cityRaw) : {};
  const url = new URL("https://app.ticketmaster.com/discovery/v2/events.json");
  url.searchParams.set("apikey", TM_API_KEY);
  url.searchParams.set("size", "100");
  url.searchParams.set("sort", "date,asc");
  url.searchParams.set("segmentName", "Music");
  if (loc.countryCode) url.searchParams.set("countryCode", loc.countryCode);
  if (loc.stateCode)   url.searchParams.set("stateCode", loc.stateCode);
  if (loc.city)        url.searchParams.set("city", loc.city);
  url.searchParams.set("startDateTime", toISO8601UTC(start));
  url.searchParams.set("endDateTime",   toISO8601UTC(end));

  let items = [];
  const _debug = [];

  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 5000);
    const resp = await fetch(url.toString(), { method: "GET", signal: ac.signal });
    clearTimeout(t);

    const ct = resp.headers.get("content-type") || "";
    if (!resp.ok || !/json/i.test(ct)) {
      const txt = await resp.text().catch(() => "");
      console.warn(`🎫 [TM][${rid}] non-JSON or non-200:`, resp.status, txt.slice(0, 200));
      return res.json(debug ? [{ _debug: [{ status: resp.status, ct, preview: txt.slice(0, 400) }] }] : []);
    }

    const data = await resp.json().catch(() => ({}));
    const list = data?._embedded?.events ?? [];

    items = list.map((ev) => {
      const venue = ev?._embedded?.venues?.[0] || {};
      const hero  =
        pickHero(ev?.images) ||
        pickHero(ev?._embedded?.attractions?.[0]?.images) ||
        (typeof ev?.seatmap?.staticUrl === "string" ? ev.seatmap.staticUrl.replace(/^http:/i, "https:") : null);

      const when =
        ev?.dates?.start?.dateTime ||
        (ev?.dates?.start?.localDate
          ? `${ev.dates.start.localDate}T${ev.dates.start.localTime || "00:00:00"}Z`
          : new Date());

      const item = {
        id: String(ev?.id || ev?.url || ev?.name || Math.random()),
        title: String(ev?.name || "Event"),
        venueName: String(venue?.name || ""),
        address: joinAddress([
          venue?.address?.line1,
          venue?.city?.name,
          venue?.state?.stateCode || venue?.state?.name,
          venue?.country?.countryCode,
        ]),
        date: toISO8601UTC(new Date(when)),
        price: safeNumber(ev?.priceRanges?.[0]?.min),
        externalURL: typeof ev?.url === "string" ? ev.url : null,
        source: "ticketmaster",
        heroImage: hero || null,
      };
      item.imageURL = item.heroImage || null; // back-compat
      return item;
    });
  } catch (e) {
    console.error(`🎫 [TM][${rid}] fetch error`, e);
    if (debug) _debug.push({ error: String(e) });
  }

  const requireImage = (Q("requireImage") || "0") === "1";
  if (requireImage) items = items.filter((x) => !!x.heroImage);

  const imagesFirst = (Q("imagesFirst") ?? "1") !== "0";
  if (imagesFirst) {
    items.sort((a, b) => {
      const ai = a.heroImage ? 1 : 0;
      const bi = b.heroImage ? 1 : 0;
      if (ai !== bi) return bi - ai;
      return new Date(a.date) - new Date(b.date);
    });
  } else {
    items.sort((a, b) => new Date(a.date) - new Date(b.date));
  }

  return res.json(debug ? [{ _debug }, ...items] : items);
});

exports.feedEventbrite = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  // ---- Local helpers ----
  const Q = (k) => (req.query && req.query[k]) || (req.body && req.body[k]) || null;
  const toISO8601UTC = (d) => new Date(d).toISOString().replace(/\.\d{3}Z$/, "Z");
  const nightWindow = (days = 14) => {
    const start = new Date(); start.setUTCHours(0,0,0,0);
    const end = new Date(start); end.setUTCDate(end.getUTCDate() + days); end.setUTCHours(23,59,59,999);
    return { start, end };
  };

  // ---- Config
  let EVENTBRITE_TOKEN = "";
  try {
    const c = functions.config();
    EVENTBRITE_TOKEN = (c.eventbrite && c.eventbrite.token) || process.env.EVENTBRITE_TOKEN || "";
  } catch {
    EVENTBRITE_TOKEN = process.env.EVENTBRITE_TOKEN || "";
  }

  const debug = String(Q("debug") || "0") === "1";
  const rid = Math.random().toString(36).slice(2, 8);
  const { start, end } = nightWindow(14);

  if (!EVENTBRITE_TOKEN) {
    console.warn(`🟠 [EB][${rid}] EVENTBRITE_TOKEN missing → []`);
    return res.json(debug ? [{ _debug: [{ error: "Eventbrite token missing" }] }] : []);
  }

  const city = Q("city");
  const within = Q("within") || "50mi"; // default radius to avoid empty results
  const requireImage = (Q("requireImage") || "0") === "1";
  const imagesFirst = (Q("imagesFirst") ?? "1") !== "0";

  const NIGHTLIFE_Q = [
    "nightlife","party","club","lounge","dj","club night","rave",
    "afrobeats","amapiano","hip hop","dancehall","soca",
    "reggaeton","latin","salsa","bachata","kizomba"
  ].join(" OR ");
  const MUSIC_CATEGORY = "103";

  const _debug = [];

  async function searchEB({ useCategory, useKeywords }) {
    const url = new URL("https://www.eventbriteapi.com/v3/events/search/");
    url.searchParams.set("sort_by", "date");
    url.searchParams.set("expand", "venue,logo,organizer");
    url.searchParams.set("page_size", "50");
    url.searchParams.set("start_date.range_start", toISO8601UTC(start));
    url.searchParams.set("start_date.range_end",   toISO8601UTC(end));
    if (city) {
      url.searchParams.set("location.address", city);
      url.searchParams.set("location.within", within);
    }
    if (useCategory) url.searchParams.set("categories", MUSIC_CATEGORY);
    if (useKeywords) url.searchParams.set("q", NIGHTLIFE_Q);

    const ac = new AbortController();
    const t  = setTimeout(() => ac.abort(), 6000);
    try {
      const resp = await fetch(url.toString(), {
        method: "GET",
        headers: { Authorization: `Bearer ${EVENTBRITE_TOKEN}` },
        signal: ac.signal,
      });
      const ct = resp.headers.get("content-type") || "";
      if (!resp.ok || !/json/i.test(ct)) {
        const txt = await resp.text().catch(() => "");
        _debug.push({ try: { useCategory, useKeywords }, status: resp.status, ct, preview: txt.slice(0, 200) });
        return [];
      }
      const data = await resp.json().catch(() => ({}));
      const list = Array.isArray(data?.events) ? data.events : [];
      _debug.push({ try: { useCategory, useKeywords }, found: list.length, rate: {
        remaining: resp.headers.get("X-RateLimit-Remaining"),
        limit: resp.headers.get("X-RateLimit-Limit")
      }});
      return list;
    } catch (e) {
      _debug.push({ try: { useCategory, useKeywords }, error: String(e?.message || e) });
      return [];
    } finally {
      clearTimeout(t);
    }
  }

  // Try progressively broader searches
  let events = await searchEB({ useCategory: true,  useKeywords: true  });
  if (!events.length) events = await searchEB({ useCategory: true,  useKeywords: false });
  if (!events.length) events = await searchEB({ useCategory: false, useKeywords: true  });
  if (!events.length) events = await searchEB({ useCategory: false, useKeywords: false });

  // Map → ExternalFeedItem
  let items = events.map((ev) => {
    const v = ev?.venue || {};
    const when = ev?.start?.utc || ev?.start?.local || new Date();
    const address =
      v?.address?.localized_address_display ||
      v?.localized_address_display ||
      (v?.name ? String(v.name) : "");

    const hero =
      ev?.logo?.url ||
      ev?.logo?.original?.url ||
      ev?.logo?.crop_mask?.url ||
      ev?.organizer?.logo?.url ||
      null;

    const item = {
      id: String(ev?.id || ev?.url || ev?.name?.text || Math.random()),
      title: String(ev?.name?.text || ev?.name || ev?.summary || "Event"),
      venueName: String(v?.name || ""),
      address,
      date: toISO8601UTC(new Date(when)),
      price: null,
      externalURL: typeof ev?.url === "string" ? ev.url : null,
      source: "eventbrite",
      heroImage: hero,
    };
    item.imageURL = item.heroImage || null; // back-compat
    return item;
  });

  // Apply requireImage after broadening
  if (requireImage) items = items.filter((x) => !!x.heroImage);

  // Sort
  if (imagesFirst) {
    items.sort((a, b) => {
      const ai = a.heroImage ? 1 : 0;
      const bi = b.heroImage ? 1 : 0;
      if (ai !== bi) return bi - ai;
      return new Date(a.date) - new Date(b.date);
    });
  } else {
    items.sort((a, b) => new Date(a.date) - new Date(b.date));
  }

  return res.json(debug ? [{ _debug }, ...items] : items);
});

// =========================
// Firestore + RTDB triggers
// =========================

exports.sendNewMessageNotification = fn.firestore
  .document("directChats/{chatId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Direct chat trigger");

    const data = snap.data() || {};
    const { senderId, recipientId, text = "New message" } = data;
    const chatId = context.params.chatId;

    if (!recipientId || !senderId) {
      console.warn("❌ Missing recipientId or senderId in message data");
      return;
    }

    const tokenSnap = await rtdb.ref(`users/${recipientId}/onesignalUserId`).get();
    const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
    if (!oneSignalId) {
      console.warn(`ℹ️ No OneSignal Player ID for recipient ${recipientId}`);
      return;
    }

    let senderName = "Someone";
    try {
      const senderSnap = await rtdb.ref(`users/${senderId}/name`).get();
      if (senderSnap.exists()) senderName = senderSnap.val();
    } catch {}

    let payload = {
      app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
      include_player_ids: [oneSignalId],
      headings: { en: `New message from ${senderName}` },
      contents: { en: String(text || "").substring(0, 100) },
      data: { chatId, senderId, senderName, type: "direct" },
    };
    payload = withIOSCategory(payload, IOS_CATEGORIES.CHAT, `chat_${chatId}`);

    try {
      const response = await fetch("https://onesignal.com/api/v1/notifications", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization:
            "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
        },
        body: JSON.stringify(payload),
      });
      console.log("📤 Notification sent (direct):", await response.json());
    } catch (err) {
      console.error("🔥 Failed to send direct notification:", err);
    }
  });

exports.sendNewGroupMessageNotification = fn.firestore
  .document("groups/{groupId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Group message trigger");

    const data = snap.data() || {};
    const { senderId, text = "New group message" } = data;
    const groupId = context.params.groupId;

    let senderName = "Someone";
    try {
      const senderSnap = await firestore.collection("users").doc(senderId).get();
      if (senderSnap.exists) senderName = senderSnap.data().name || "Someone";
    } catch {}

    let memberIds = [];
    try {
      const membersSnap = await firestore.collection(`groups/${groupId}/members`).get();
      memberIds = membersSnap.docs.map((doc) => doc.id);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await rtdb.ref(`users/${userId}/onesignalUserId`).get();
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
        if (!oneSignalId) continue;

        let payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: `New message from ${senderName}` },
          contents: { en: String(text || "").substring(0, 100) },
          data: { groupId, senderId, senderName, type: "group" },
        };
        payload = withIOSCategory(payload, IOS_CATEGORIES.CHAT, `group_${groupId}`);

        const response = await fetch("https://onesignal.com/api/v1/notifications", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization:
              "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
          },
          body: JSON.stringify(payload),
        });
        console.log(`📤 Notification sent to ${userId}:`, await response.json());
      } catch (err) {
        console.error(`🔥 Failed to notify ${userId}:`, err);
      }
    }
  });

exports.sendGroupMessageLikeNotification = fn.firestore
  .document("groups/{groupId}/messages/{messageId}")
  .onUpdate(async (change, context) => {
    logStamp("📡 OneSignal: Group like trigger");

    const before = change.before.data() || {};
    const after = change.after.data() || {};
    const beforeLikes = before.likes || [];
    const afterLikes = after.likes || [];
    const newLikes = afterLikes.filter((uid) => !beforeLikes.includes(uid));
    if (newLikes.length === 0) return;

    const senderId = newLikes[0];
    const { groupId, messageId } = context.params;

    let memberIds = [];
    try {
      const membersSnap = await firestore.collection(`groups/${groupId}/members`).get();
      memberIds = membersSnap.docs.map((doc) => doc.id);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await rtdb.ref(`users/${userId}/onesignalUserId`).get();
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
        if (!oneSignalId) continue;

        let payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: "❤️ A message was liked!" },
          contents: { en: "Tap to view the liked message." },
          data: { groupId, messageId, type: "group_like" },
        };
        payload = withIOSCategory(payload, IOS_CATEGORIES.CHAT, `group_${groupId}`);

        const response = await fetch("https://onesignal.com/api/v1/notifications", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization:
              "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
          },
          body: JSON.stringify(payload),
        });
        console.log(`📤 Like notification sent to ${userId}:`, await response.json());
      } catch (err) {
        console.error(`🔥 Failed to send like notification to ${userId}:`, err);
      }
    }
  });

exports.sendGroupMessageCommentNotification = fn.firestore
  .document("groups/{groupId}/messages/{messageId}/comments/{commentId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Group comment trigger");

    const { groupId, messageId } = context.params;
    const comment = snap.data() || {};
    const senderId = comment.userId;
    const commentText = comment.text || "New comment";

    let memberIds = [];
    try {
      const membersSnap = await firestore.collection(`groups/${groupId}/members`).get();
      memberIds = membersSnap.docs.map((doc) => doc.id);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await rtdb.ref(`users/${userId}/onesignalUserId`).get();
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
        if (!oneSignalId) continue;

        let payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: "💬 New Comment in Group Chat" },
          contents: { en: String(commentText || "").substring(0, 100) },
          data: { groupId, messageId, type: "group_comment" },
        };
        payload = withIOSCategory(payload, IOS_CATEGORIES.CHAT, `group_${groupId}`);

        const response = await fetch("https://onesignal.com/api/v1/notifications", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization:
              "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
          },
          body: JSON.stringify(payload),
        });
        console.log(`📤 Comment notification sent to ${userId}:`, await response.json());
      } catch (err) {
        console.error(`🔥 Failed to send comment notification to ${userId}:`, err);
      }
    }
  });

// When a purchase is created, send an (immediate) reminder-style push
exports.sendEventReminderNotification = fn.database
  .ref("purchases/{userId}/{purchaseId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Event reminder trigger");

    const { userId } = context.params;
    const data = snap.val() || {};
    const { eventName = "Your Event", eventId, eventTime } = data;

    const tokenSnap = await rtdb.ref(`users/${userId}/onesignalUserId`).get();
    const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
    if (!oneSignalId) {
      console.warn(`ℹ️ No OneSignal Player ID for user ${userId}`);
      return;
    }

    let payload = {
      app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
      include_player_ids: [oneSignalId],
      headings: { en: "🎉 Event Reminder" },
      contents: { en: `Don't miss ${eventName}! It starts soon.` },
      data: { eventId, eventName, eventTime, type: "event_reminder" },
    };
    payload = withIOSCategory(payload, IOS_CATEGORIES.EVENT, eventId ? `event_${eventId}` : undefined);

    try {
      const response = await fetch("https://onesignal.com/api/v1/notifications", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization:
            "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
        },
        body: JSON.stringify(payload),
      });
      console.log(`📤 Event reminder sent to ${userId}:`, await response.json());
    } catch (err) {
      console.error(`🔥 Event reminder failed for ${userId}:`, err);
    }
  });


/// ===================================================
// Nightlife Approvals — callable functions
// ===================================================
exports.submitNightlifeApplication = fn.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }
  const uid = context.auth.uid;

  const {
    type,
    fullName = "",
    email = "",
    phone = "",
    businessName = "",
    stageName = "",
    website = null,
    instagram = null,
    tiktok = null,
    description = null,
  } = data || {};

  if (!["promoter", "venue", "entertainer"].includes(type)) {
    throw new functions.https.HttpsError("invalid-argument", "type must be 'promoter' | 'venue' | 'entertainer'");
  }
  if (!fullName || !email) {
    throw new functions.https.HttpsError("invalid-argument", "fullName and email are required");
  }

  const node =
    type === "promoter" ? "promoterApplications" :
    type === "venue"    ? "venueApplications"    :
                          "entertainerApplications";

  const payload = {
    uid,
    type,
    fullName,
    email,
    phone,
    businessName,
    ...(type === "entertainer" ? { stageName } : {}),
    website,
    instagram,
    tiktok,
    description,
    status: "pending",
    approved: false,
    suspended: false,
    submittedAt: admin.database.ServerValue.TIMESTAMP,
  };

  await rtdb.ref(`${node}/${uid}`).set(payload);
  return { ok: true };
});

exports.listNightlifeApplications = fn.https.onCall(async (data) => {
  const { type, status = "pending", limit = 200 } = data || {};
  if (!["promoter", "venue", "entertainer"].includes(type)) {
    throw new functions.https.HttpsError("invalid-argument", "type must be 'promoter' | 'venue' | 'entertainer'");
  }
  if (!["pending", "approved", "rejected"].includes(status)) {
    throw new functions.https.HttpsError("invalid-argument", "status must be 'pending' | 'approved' | 'rejected'");
  }

  const node =
    type === "promoter" ? "promoterApplications" :
    type === "venue"    ? "venueApplications"    :
                          "entertainerApplications";

  const snap = await rtdb
    .ref(node)
    .orderByChild("status")
    .equalTo(status)
    .limitToFirst(limit)
    .get();

  const items = [];
  snap.forEach((child) => {
    const v = child.val() || {};
    items.push({
      uid: child.key,
      type: v.type || type,
      fullName: v.fullName || "",
      email: v.email || "",
      phone: v.phone || "",
      businessName: v.businessName || "",
      website: v.website ?? null,
      instagram: v.instagram ?? null,
      tiktok: v.tiktok ?? null,
      description: v.description ?? null,
      status: v.status || "pending",
      suspended: !!v.suspended,
      submittedAt: v.submittedAt || null,
    });
  });

  return { items };
});

async function assertStaff(context) {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in required.");
  if (uid === SUPERADMIN_UID) return;
  const [a, s] = await Promise.all([
    rtdb.ref(`admins/${uid}`).get().catch(() => null),
    rtdb.ref(`superadmin/${uid}`).get().catch(() => null),
  ]);
  const ok = (a?.val() === true) || (s?.val() === true);
  if (!ok) throw new functions.https.HttpsError("permission-denied", "Admin only.");
}

exports.reviewNightlifeApplication = fn.https.onCall(async (data, context) => {
  const { HttpsError } = functions.https;
  try {
    await assertStaff(context);

    const { type, uid, action, reason = null, venue = null } = data || {};
    const ALLOWED_TYPES = new Set(["promoter", "venue", "entertainer"]);
    const ALLOWED_ACTIONS = new Set(["approve", "reject", "suspend", "reinstate"]);

    if (!ALLOWED_TYPES.has(type)) throw new HttpsError("invalid-argument", "Bad type");
    if (!uid || !ALLOWED_ACTIONS.has(action)) throw new HttpsError("invalid-argument", "uid and valid action required");

    const appNode =
      type === "promoter" ? "promoterApplications" :
      type === "venue"    ? "venueApplications"    :
                            "entertainerApplications";

    const appRef = rtdb.ref(`${appNode}/${uid}`);
    const appSnap = await appRef.get();
    if (!appSnap.exists()) throw new HttpsError("not-found", "Application not found");
    const app = appSnap.val() || {};
    const now = admin.database.ServerValue.TIMESTAMP;

    const updates = {};
    const set = (path, val) => { updates[path] = val; };
    const markReviewed = () => {
      set(`${appNode}/${uid}/reviewedAt`, now);
      set(`${appNode}/${uid}/reviewedBy`, context.auth?.uid || null);
    };

    if (action === "reject") {
      set(`${appNode}/${uid}/status`, "rejected");
      set(`${appNode}/${uid}/approved`, false);
      set(`${appNode}/${uid}/suspended`, false);
      if (reason) set(`${appNode}/${uid}/reason`, String(reason));
      markReviewed();
      await rtdb.ref().update(updates);
      return { ok: true, action, status: "rejected", type };
    }

    if (action === "suspend" || action === "reinstate") {
      const suspended = action === "suspend";
      set(`${appNode}/${uid}/suspended`, suspended);
      set(`${appNode}/${uid}/moderatedAt`, now);
      set(`${appNode}/${uid}/moderatedBy`, context.auth?.uid || null);

      if (type === "promoter") {
        set(`promoters/${uid}/suspended`, suspended);
        set(`promoters/${uid}/moderatedAt`, now);
        set(`promoters/${uid}/moderatedBy`, context.auth?.uid || null);
      } else if (type === "entertainer") {
        set(`entertainers/${uid}/suspended`, suspended);
        set(`entertainers/${uid}/moderatedAt`, now);
        set(`entertainers/${uid}/moderatedBy`, context.auth?.uid || null);
      } else {
        const ownerSnap = await rtdb.ref(`venueOwners/${uid}`).get();
        const owner = ownerSnap.exists() ? ownerSnap.val() || {} : {};
        const venueId = owner.venueId || null;

        set(`venueOwners/${uid}/suspended`, suspended);
        set(`venueOwners/${uid}/moderatedAt`, now);
        set(`venueOwners/${uid}/moderatedBy`, context.auth?.uid || null);

        if (venueId) {
          set(`venues/${venueId}/suspended`, suspended);
          set(`venues/${venueId}/moderatedAt`, now);
          set(`venues/${venueId}/moderatedBy`, context.auth?.uid || null);
        }
      }

      await rtdb.ref().update(updates);
      return { ok: true, action, suspended, type };
    }

    // APPROVE
    set(`${appNode}/${uid}/status`, "approved");
    set(`${appNode}/${uid}/approved`, true);
    set(`${appNode}/${uid}/suspended`, false);
    set(`${appNode}/${uid}/approvedAt`, now);
    markReviewed();

    if (type === "promoter") {
      set(`promoters/${uid}/approved`, true);
      set(`promoters/${uid}/suspended`, false);
      set(`promoters/${uid}/createdAt`, now);
      await rtdb.ref().update(updates);
      return { ok: true, action: "approve", status: "approved", type };
    }

    if (type === "entertainer") {
      const stageName =
        (app.stageName && String(app.stageName).trim()) ||
        (app.businessName && String(app.businessName).trim()) || "";

      set(`entertainers/${uid}/approved`, true);
      set(`entertainers/${uid}/approvedAt`, now);
      set(`entertainers/${uid}/suspended`, false);
      set(`entertainers/${uid}/createdAt`, now);

      set(`entertainers/${uid}/uid`, uid);
      set(`entertainers/${uid}/sourceApplication`, "entertainerApplications");

      if (app.fullName)      set(`entertainers/${uid}/fullName`, app.fullName);
      if (stageName)         set(`entertainers/${uid}/stageName`, stageName);
      if (app.businessName)  set(`entertainers/${uid}/businessName`, app.businessName);
      if (app.email)         set(`entertainers/${uid}/email`, app.email);
      if (app.phone)         set(`entertainers/${uid}/phone`, app.phone);
      if (app.instagram)     set(`entertainers/${uid}/instagram`, app.instagram);
      if (app.tiktok)        set(`entertainers/${uid}/tiktok`, app.tiktok);
      if (app.website)       set(`entertainers/${uid}/website`, app.website);
      if (app.description)   set(`entertainers/${uid}/description`, app.description);

      await rtdb.ref().update(updates);
      return { ok: true, action: "approve", status: "approved", type };
    }

    // venue approval
    let venueId =
      venue && typeof venue.venueId === "string" && venue.venueId.trim()
        ? venue.venueId.trim()
        : "";

    if (!venueId) {
      const newRef = rtdb.ref("venues").push();
      venueId = newRef.key;
      await newRef.set({
        name: (venue && venue.name) || app.businessName || "",
        address: (venue && venue.address) || "",
        approved: true,
        suspended: false,
        createdAt: now,
      });
    } else {
      const vUpdates = { approved: true, suspended: false };
      if (venue?.name && venue.name.trim()) vUpdates.name = venue.name.trim();
      if (venue?.address && venue.address.trim()) vUpdates.address = venue.address.trim();
      await rtdb.ref(`venues/${venueId}`).update(vUpdates);
    }

    set(`venueAdmins/${venueId}/${uid}`, true);
    set(`venueOwners/${uid}/venueId`, venueId);
    set(`venueOwners/${uid}/approved`, true);
    set(`venueOwners/${uid}/suspended`, false);
    set(`venueOwners/${uid}/linkedAt`, now);
    set(`${appNode}/${uid}/venueId`, venueId);

    await rtdb.ref().update(updates);
    return { ok: true, action: "approve", status: "approved", type, venueId };
  } catch (e) {
    console.error("reviewNightlifeApplication error:", e);
    if (e instanceof functions.https.HttpsError) throw e;
    throw new functions.https.HttpsError(
      "internal",
      "reviewNightlifeApplication failed",
      { message: e?.message || String(e), stack: e?.stack, name: e?.name }
    );
  }
});

// -------- Admin: Brands (approve/suspend/delete) --------
exports.adminApproveBrand = functions.https.onCall(async (data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Sign in required.");

  let isStaff = (uid === SUPERADMIN_UID);
  if (!isStaff) {
    const [adminSnap, superSnap] = await Promise.all([
      rtdb.ref(`admins/${uid}`).get().catch(() => null),
      rtdb.ref(`superadmin/${uid}`).get().catch(() => null),
    ]);
    isStaff = (adminSnap?.val() === true) || (superSnap?.val() === true);
  }
  if (!isStaff) throw new functions.https.HttpsError("permission-denied", "Admin only.");

  const brandId = String(data?.brandId || "").trim();
  if (!brandId) throw new functions.https.HttpsError("invalid-argument", "brandId required.");

  await rtdb.ref(`brands/${brandId}`).update({ approved: true, suspended: false });

  const secret = functions.config().meta?.invite_secret;
  const host = functions.config().app?.host || "https://blackapp.io";
  if (!secret) throw new functions.https.HttpsError("failed-precondition", "Missing meta.invite_secret");

  const payload = JSON.stringify({ brandId, iat: Date.now() });
  const sig = crypto.createHmac("sha256", secret).update(payload).digest("hex");
  const invite = Buffer.from(`${payload}.${sig}`).toString("base64url");

  const url = `${host}/connect/social.html?brandId=${encodeURIComponent(brandId)}&invite=${encodeURIComponent(invite)}`;

  await rtdb.ref(`brands/${brandId}`).update({
    igInviteUrl: url,
    igInviteCreatedAt: Date.now(),
  });

  return { ok: true, igInviteUrl: url };
});

exports.adminSuspendBrand = functions.https.onCall(async (data, context) => {
  await assertStaff(context);
  const brandId = String(data?.brandId || "").trim();
  const suspended = !!data?.suspended;
  if (!brandId) throw new functions.https.HttpsError("invalid-argument", "brandId required.");
  await rtdb.ref(`brands/${brandId}`).update({ suspended });
  return { ok: true, brandId, suspended };
});

exports.adminDeleteBrand = functions.https.onCall(async (data, context) => {
  await assertStaff(context);
  const brandId = String(data?.brandId || "").trim();
  if (!brandId) throw new functions.https.HttpsError("invalid-argument", "brandId required.");
  await rtdb.ref(`brands/${brandId}`).set(null);
  return { ok: true, brandId };
});

// Upsert a gossip partner (HTTPS, guarded by ADMIN_INIT_KEY)
// Usage (POST): /upsertGossipPartner?key=YOUR_ADMIN_INIT_KEY
exports.upsertGossipPartner = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    // auth
    const key = String(req.query.key || "");
    if (!key || key !== (process.env.ADMIN_INIT_KEY || (functions.config().admin && functions.config().admin.init_key))) {
      return res.status(401).json({ error: "unauthorized" });
    }

    const body = (req.headers["content-type"] || "").includes("application/json")
      ? req.body
      : {};

    const id       = String((body.id || req.query.id || "")).trim().toLowerCase();
    const title    = String((body.title || req.query.title || "")).trim();
    const pageId   = String((body.pageId || req.query.pageId || "")).trim();
    let   igUserId = String((body.igUserId || req.query.igUserId || "")).trim();
    const enabled  = String((body.enabled ?? req.query.enabled ?? "true")).toLowerCase() !== "false";

    if (!id) return res.status(400).json({ error: "id required" });
    if (!pageId && !igUserId) return res.status(400).json({ error: "pageId or igUserId required" });

    // Resolve IG user id if needed
    if (!igUserId && pageId) {
      const token = getMetaPageToken() || getMetaUserToken();
      if (!token) return res.status(500).json({ error: "Meta token not configured" });
      igUserId = await resolveIgUserId(pageId, token);
    }

    const payload = {
      title: title || `${id} — Instagram`,
      pageId: pageId || null,
      igUserId,
      enabled,
      lastSyncTs: 0,
    };

    await rtdb.ref(`gossip/partners/${id}`).update(payload);
    return res.json({ ok: true, id, ...payload });
  } catch (e) {
    console.error("upsertGossipPartner error:", e);
    return res.status(500).json({ error: String(e?.message || e) });
  }
});



// Admin-only: set gossip cutoff
exports.adminSetGossipCutoff = fn.https.onRequest(async (req, res) => {
  try {
    const key = String(req.query.key || "");
    const id  = String(req.query.id || "");
    const ts  = Number(req.query.ts || "0");
    if (!key || key !== ADMIN_INIT_KEY) return res.status(401).json({ error: "unauthorized" });
    if (!id || !Number.isFinite(ts))   return res.status(400).json({ error: "bad params" });
    await rtdb.ref(`gossip/partners/${id}/lastSyncTs`).set(ts);
    res.json({ ok: true, id, lastSyncTs: ts });
  } catch (e) {
    res.status(500).json({ error: String(e?.message || e) });
  }
});

// Admin-only: purge partner items (for fresh backfill)
exports.adminPurgeGossipItems = fn.https.onRequest(async (req, res) => {
  try {
    const key = String(req.query.key || "");
    const id  = String(req.query.id || "");
    if (!key || key !== ADMIN_INIT_KEY) return res.status(401).json({ error: "unauthorized" });
    if (!id) return res.status(400).json({ error: "bad params" });
    await rtdb.ref(`gossip/items/${id}`).set(null);
    res.json({ ok: true, purged: id });
  } catch (e) {
    res.status(500).json({ error: String(e?.message || e) });
  }
});


// One-off: backfill missing thumbs for a partner's IG items
// GET /backfillIgThumbs?partner=a1lounge
// One-off: backfill/normalize IG thumbs for a partner's items
// ✅ Enforces the SAME 25%-logo fallback logic as everywhere else via /imgThumb
// GET /backfillIgThumbs?partner=a1loungeclt
exports.backfillIgThumbs = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const partnerId = String(req.query.partner || "").trim();
    if (!partnerId) {
      return res.status(400).json({ ok: false, error: "Missing ?partner=" });
    }

    // Load all items newest-first (keys under /gossip/items/{partnerId})
    const snap = await rtdb
      .ref(`gossip/items/${partnerId}`)
      .orderByChild("timestamp")
      .get();

    if (!snap.exists()) {
      return res.json({ ok: true, partnerId, scanned: 0, updated: 0, skipped: 0 });
    }

    // Helper: force HTTPS or null
    const toHttps = (u) => {
      try {
        if (!u) return null;
        const url = new URL(String(u));
        url.protocol = "https:";
        return url.toString();
      } catch {
        return null;
      }
    };

    // Build the canonical imgThumb URL with 25% centered logo fallback
    const buildThumb = (rawUrl, w = 900) =>
      cfUrl("imgThumb", {
        url: rawUrl || "",
        w,
        fallback: getLogoFallback(),
        fallbackScale: 0.25,
      });

    let scanned = 0;
    let updated = 0;
    let skipped = 0;

    const updates = {};

    snap.forEach((cs) => {
      scanned++;

      const v = cs.val() || {};
      const key = cs.key;

      // Choose best available upstream visual, then normalize to https
      // Priority: image → rawThumbUrl → rawMediaUrl
      const canonicalImage =
        toHttps(v.image) ||
        toHttps(v.rawThumbUrl) ||
        toHttps(v.rawMediaUrl) ||
        null;

      // Enforce our standard 25% logo fallback thumb via proxy
      const desiredThumb = buildThumb(canonicalImage, 900);

      // What is currently stored?
      const currentThumb = v.thumb || null;
      const currentImage = v.image || null;

      const needThumbUpdate = currentThumb !== desiredThumb;
      const needImageHttpsUpdate =
        !!currentImage && /^http:\/\//i.test(String(currentImage));

      // If we don't have any visual at all, we still want a branded thumb (logo fallback),
      // so we will write the thumb even if canonicalImage is null/empty.
      if (needThumbUpdate || needImageHttpsUpdate) {
        if (needThumbUpdate) {
          updates[`gossip/items/${partnerId}/${key}/thumb`] = desiredThumb;
        }
        if (needImageHttpsUpdate && canonicalImage) {
          updates[`gossip/items/${partnerId}/${key}/image`] = canonicalImage;
        }
        updated++;
      } else {
        // Already compliant
        skipped++;
      }
    });

    if (updated) {
      await rtdb.ref().update(updates);
    }

    return res.json({
      ok: true,
      partnerId,
      scanned,
      updated,
      skipped,
      note: "thumbs normalized via /imgThumb with 25% centered logo fallback",
    });
  } catch (e) {
    console.warn("[IG BACKFILL] error:", e?.message || e);
    return res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});
// ====================================================
// MARK: Tumblr curation — Admin & helpers
// ====================================================

// RTDB model: gossip/tumblrBlogs/{key} => { url, title, enabled }
// Guarded writes with ADMIN_INIT_KEY

exports.upsertTumblrBlog = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const key = String(req.query.key || "");
    const adminKey =
      process.env.ADMIN_INIT_KEY ||
      (functions.config().admin && functions.config().admin.init_key);
    if (!key || key !== adminKey) return res.status(401).json({ error: "unauthorized" });

    const body =
      (req.headers["content-type"] || "").includes("application/json") ? req.body : {};

    const id = String((body.id || req.query.id || "")).trim().toLowerCase();
    let url  = String((body.url || req.query.url || "")).trim();
    const title = String((body.title || req.query.title || "")).trim();
    const enabled = String(body.enabled ?? req.query.enabled ?? "true").toLowerCase() !== "false";

    if (!id) return res.status(400).json({ error: "id required" });
    if (!url || !/^https?:\/\/.+/i.test(url)) return res.status(400).json({ error: "valid url required" });

    // Normalize to Tumblr RSS if a root/blog URL was provided
    if (!/\/rss$/i.test(url)) url = url.replace(/\/+$/, "") + "/rss";
    url = url.replace(/^http:/i, "https:");

    const payload = { url, title: title || id, enabled, updatedAt: Date.now() };
    await rtdb.ref(`gossip/tumblrBlogs/${id}`).update(payload);
    return res.json({ ok: true, id, ...payload });
  } catch (e) {
    console.error("upsertTumblrBlog error:", e);
    return res.status(500).json({ error: String(e?.message || e) });
  }
});

// Optional: list curated Tumblr blogs (admin-guarded)
exports.listTumblrBlogs = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const key = String(req.query.key || "");
    const adminKey =
      process.env.ADMIN_INIT_KEY ||
      (functions.config().admin && functions.config().admin.init_key);
    if (!key || key !== adminKey) return res.status(401).json({ error: "unauthorized" });

    const snap = await rtdb.ref("gossip/tumblrBlogs").get();
    const blogs = snap.exists() ? snap.val() : {};
    const items = Object.entries(blogs).map(([id, v]) => ({ id, ...(v || {}) }));
    return res.json({ ok: true, count: items.length, items });
  } catch (e) {
    console.error("listTumblrBlogs error:", e);
    return res.status(500).json({ error: String(e?.message || e) });
  }
});

// ---- Tumblr parsing helpers (local to probe) ----
function firstImgFromHtml(html = "") {
  try {
    const m = String(html).match(/<img[^>]+src=["']([^"']+)["']/i);
    return m ? m[1] : null;
  } catch { return null; }
}
function pickTumblrImage(it) {
  const encUrl =
    (it.enclosure && (it.enclosure.url || it.enclosure.href)) ||
    (it["media:content"] && (it["media:content"].url || it["media:content"]["@_url"])) ||
    it.image?.url ||
    it.thumbnail ||
    null;

  const htmlBlob =
    it["content:encoded"] || it.content || it.description || it.summary || "";
  const htmlImg = firstImgFromHtml(htmlBlob);

  const url = (encUrl || htmlImg || "").replace(/^http:/i, "https:");
  return url || null;
}

// ---- Minimal XML fetch using native fetch + timeout (Node 18+/20) ----
async function fetchXml(url, timeoutMs = 5000) {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const resp = await fetch(url, {
      method: 'GET',
      headers: {
        'user-agent': 'blackapp/1.0 (+https://blackapp.io; CloudFunctions)',
        'accept': 'application/rss+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5',
        'accept-language': 'en-US,en;q=0.8'
      },
      signal: ac.signal
    });
    if (!resp.ok) {
      // still try to read body for debug
      const text = await resp.text().catch(() => "");
      throw new Error(`HTTP ${resp.status} ${resp.statusText} ${text.slice(0, 120)}`);
    }
    return await resp.text();
  } finally {
    clearTimeout(t);
  }
}

// ====================================================
// MARK: Tumblr curated bundle — DEPRECATED shim
// This endpoint is no longer needed because /rssBundle already includes Tumblr.
// We return a filtered view from the cache so browser checks still work.
// ====================================================
exports.rssTumblrBundle = fn
  .runWith({ timeoutSeconds: 10, memory: "256MB" })
  .https.onRequest(async (req, res) => {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).end();
    }
    res.set("Access-Control-Allow-Origin", "*");

    try {
      const thumbWidth = Math.min(Math.max(parseInt(req.query.thumbWidth || "900", 10) || 900, 120), 1600);
      const perFeedLimit = Math.min(Math.max(parseInt(req.query.perFeedLimit || "8", 10) || 8, 1), 30);

      const snap = await rtdb.ref("gossip/rssCache/latest").get();
      const cached = snap.exists() ? (snap.val() || {}) : {};
      const items = Array.isArray(cached.items) ? cached.items : [];

      const onlyTumblr = items.filter((it) => {
        try {
          const u = new URL(it.link || "about:blank");
          return u.hostname.endsWith(".tumblr.com");
        } catch {
          return String(it.source || "").toLowerCase().includes("tumblr");
        }
      }).slice(0, perFeedLimit);

      // ensure we still provide a thumb (older cache entries may not have it)
      const normalized = onlyTumblr.map((it) => ({
        ...it,
        thumb: it.thumb || cfUrl("imgThumb", {
          url: it.image || "",
          w: thumbWidth,
          fallback: getLogoFallback(),
          fallbackScale: 0.25
        })
      }));

      res.set("Cache-Control", "public, max-age=120, s-maxage=120");
      return res.status(200).json({ ok: true, deprecated: true, items: normalized });
    } catch (e) {
      console.warn("[rssTumblrBundle] shim error:", e?.message || e);
      return res.status(200).json({ ok: true, deprecated: true, items: [] });
    }
  });

// ====================================================
// MARK: Probe one Tumblr feed: GET /rssTumblrProbe?id=<id> OR ?url=<rss-url>&limit=6
// ====================================================
exports.rssTumblrProbe = fn
  .runWith({ timeoutSeconds: 20, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).end();
    }
    res.set("Access-Control-Allow-Origin", "*");

    try {
      const id   = String(req.query.id || "").trim();
      let url    = String(req.query.url || "").trim();
      const limit = Math.min(Math.max(parseInt(req.query.limit || "6", 10) || 6, 1), 30);
      const thumbWidth = Math.min(Math.max(parseInt(req.query.thumbWidth || "900", 10) || 900, 120), 1600);
      const wantRaw = String(req.query.raw || "0") === "1";

      // Resolve URL from DB if id was provided
      if (!url && id) {
        const snap = await rtdb.ref("gossip/tumblrBlogs").get();
        const blogs = snap.exists() ? snap.val() : {};
        const rec = Object.entries(blogs)
          .map(([bid, b]) => ({ bid, ...(b || {}) }))
          .find(b => (b.bid === id) || (b.title === id) || (b.url?.includes(id)));
        if (rec?.url) url = rec.url;
      }
      if (!url) return res.status(400).json({ ok:false, error:"Provide ?id=<known-id> or ?url=<rss-url>" });

      // Fetch XML with native fetch
      const xml = await fetchXml(url, 5000);
      if (!xml || !xml.trim()) return res.status(502).json({ ok:false, error:"empty xml" });

      // Parse with the same rss-parser instance you already configure at top-level
      const parsed = await parser.parseString(xml);
      const channel = parsed || {};
      const items = Array.isArray(channel.items) ? channel.items : [];

      // Normalize like bundle does, but keep small for quick visual checks
      const normalized = items.slice(0, limit).map((it, idx) => {
        const image = pickTumblrImage(it);
        const title = it.title || it["media:title"] || it["content:encoded:title"] || "Untitled";
        const link  = it.link || it.guid || "";
        const pub   = it.isoDate || it.pubDate || it.published || it.updated || new Date().toISOString();
        const thumb = cfUrl("imgThumb", { url: image || "", w: thumbWidth, fallback: getLogoFallback(), fallbackScale: 0.25 });

        return {
          idx,
          title: String(title).slice(0, 140),
          link,
          pubDate: Date.parse(pub),
          image: image || null,
          thumb
        };
      });

      const payload = {
        ok: true,
        source: url,
        channelTitle: channel.title || null,
        totalInFeed: items.length,
        previewCount: normalized.length,
        items: normalized,
        rawXmlSnippet: wantRaw ? xml.slice(0, 2000) : undefined
      };

      res.set("Cache-Control", "no-store");
      return res.status(200).json(payload);
    } catch (e) {
      console.warn("[rssTumblrProbe] error:", e?.message || e);
      return res.status(500).json({ ok:false, error:String(e?.message || e) });
    }
  });

// ---------- Normalize AI item to match your RSS cache shape ----------
function normalizeAICrewForCache(ai, thumbWidth = 900) {
  // Your cache commonly keeps: id, title, link, image?, thumb, pubDate, source, summary, kind
  const title = ai.title || "Nightlife";
  const link = ai.link || "";
  const image = ai.image || null;
  const thumb = ai.thumb || _safeCfUrl(image || "", thumbWidth);
  const pubDate = typeof ai.pubDate === "number" ? ai.pubDate : Date.parse(new Date().toISOString());

  // Try to make a tidy summary from city + tags
  const tagStr = Array.isArray(ai.tags) && ai.tags.length ? ` • ${ai.tags.join(" ")}` : "";
  const cityStr = ai.city ? `${ai.city}` : (ai.region ? ai.region : "");
  const summary = cityStr ? `${cityStr}${tagStr}` : (tagStr || "Nightlife");

  // Derive a "source" hostname if not present
  let source = ai.source || null;
  if (!source && link) {
    try { source = new URL(link).hostname.replace(/^www\./i, ""); } catch {}
  }

  return {
    id: ai.id,
    title,
    link,
    image,
    thumb,
    pubDate,
    source,
    summary,
    kind: "nightlife" // <-- important: many UIs branch on this
  };
}

// ---------- Merge AI Crew into /gossip/rssCache/latest ----------
async function rebuildRssCacheWithAI({ limit = 120, city = "", thumbWidth = 900 }) {
  // 1) read existing cache
  const cacheRef = rtdb.ref("gossip/rssCache/latest");
  const cacheSnap = await cacheRef.get();
  const cache = cacheSnap.exists() ? (cacheSnap.val() || {}) : {};
  const cachedItems = Array.isArray(cache.items) ? cache.items : [];

  // Ensure thumbs + numeric pubDate on cached
  const normalizedCached = cachedItems.map((it) => ({
    ...it,
    thumb: it.thumb || _safeCfUrl(it.image || "", thumbWidth),
    pubDate: typeof it.pubDate === "number" ? it.pubDate : Date.parse(it.pubDate || new Date().toISOString())
  }));

  // 2) fetch AI Crew bundle-shaped items (reuse existing helper)
  const aiRaw = await fetchAICrewPostsForBundle({
    limit: Math.max(40, Math.floor(limit / 2)),
    city: city || undefined,
    thumbWidth
  });

  // 3) normalize AI items to cache shape
  const aiForCache = aiRaw.map((it) => normalizeAICrewForCache(it, thumbWidth));

  // 4) merge + de-dupe + sort
  const all = [...aiForCache, ...normalizedCached];
  const seen = new Set();
  const deduped = all.filter((it) => {
    const k = `${(it.title||"").trim().toLowerCase()}@@${(it.link||"").trim().toLowerCase()}@@${(it.image||"").trim().toLowerCase()}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });

  const sorted = deduped
    .sort((a, b) => (b.pubDate || 0) - (a.pubDate || 0))
    .slice(0, limit);

  // 5) write back to the same cache path (preserve any other fields you store)
  const payload = {
    ...cache,
    updatedAt: Date.now(),
    items: sorted
  };
  await cacheRef.set(payload);

  return { wrote: sorted.length, aiAdded: aiForCache.length, cachedKept: normalizedCached.length };
}


// ====================================================
// MARK: rssCacheRebuildPlusAI — updates /gossip/rssCache/latest in-place
// GET /rssCacheRebuildPlusAI?limit=120&city=&thumbWidth=900&debug=1
// ====================================================
exports.rssCacheRebuildPlusAI = fn
  .runWith({ timeoutSeconds: 60, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).end();
    }
    res.set("Access-Control-Allow-Origin", "*");

    const debug = String(req.query.debug || "0") === "1";
    try {
      const limit = Math.min(Math.max(parseInt(req.query.limit || "120", 10) || 120, 20), 300);
      const thumbWidth = Math.min(Math.max(parseInt(req.query.thumbWidth || "900", 10) || 900, 120), 1600);
      const city = String(req.query.city || "").trim();

      const result = await rebuildRssCacheWithAI({ limit, city, thumbWidth });

      res.set("Cache-Control", "no-store");
      return res.status(200).json({ ok: true, result });
    } catch (e) {
      console.warn("[rssCacheRebuildPlusAI] error:", e?.message || e);
      const payload = { ok: false };
      if (debug) payload.error = String(e?.message || e);
      return res.status(500).json(payload);
    }
  });

// ====================================================
// MARK: Scheduler — run 5 minutes after the AI job
// ====================================================
exports.rssCacheRebuildPlusAI_Scheduled = fn
  .runWith({ timeoutSeconds: 60, memory: "512MB" })
  .pubsub.schedule("every 60 minutes")
  .timeZone("America/New_York")
  .onRun(async () => {
    // small delay relative to aiBlackAppCrew to ensure new posts exist
    try {
      await rebuildRssCacheWithAI({ limit: 120, thumbWidth: 900 });
      console.log("[rssCacheRebuildPlusAI_Scheduled] cache updated");
    } catch (e) {
      console.warn("[rssCacheRebuildPlusAI_Scheduled] error:", e?.message || e);
    }
    return null;
  });



// ==============================
// USER POSTS — IMAGE PIPELINE 🔧
// ==============================
//
// What this block provides:
// 1) Storage finalize trigger -> creates a normalized master.webp for every user post image.
// 2) HTTP image resizer -> super-fast thumbs with cache headers.
// 3) Backfill runner -> retro-generate master.webp and DB URLs for old posts.
// 4) Resolver -> return the computed URLs for any post.
//
// It writes the following fields to the *first existing* node among:
//   (a) /<postId>
//   (b) /userPosts/<uid>/<postId>
//   (c) /users/<uid>/posts/<postId>
// Fields written:
//   imageUrl  -> 900px webp
//   thumb600  -> 600px webp
//   thumb300  -> 300px webp
//   imageCdnAt -> timestamp (ms)

const BA_USER_IMG = {
  // Your raw upload prefix in Cloud Storage:
  // Supported shapes (auto-detected):
  //   - "user_posts/originals/<uid>/<postId>/<file>"
  //   - "user_posts/originals/<postId>/<file>"          (no uid)
  ORIG_PREFIX: "user_posts/originals/",

  // Where we store normalized masters:
  //   "user_posts/derived/<uid-or-null>/<postId>/master.webp"
  DERIV_PREFIX: "user_posts/derived/",

  // Allowed incoming mime types (others are ignored):
  ALLOWED_MIME: new Set(["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"]),

  // DB write-back is on:
  DB_WRITEBACK_ENABLED: true,

  // Default thumb widths we expose:
  SIZES: [300, 600, 900],

  // Cache (seconds)
  EDGE_MAX_AGE: 86400, // 24h
};

// ---------- tiny helpers ----------
function _baParseOriginalPath(name = "") {
  if (!name.startsWith(BA_USER_IMG.ORIG_PREFIX)) return null;
  // "<uid>/<postId>/<file>"  OR  "<postId>/<file>"
  const tail = name.slice(BA_USER_IMG.ORIG_PREFIX.length);
  const parts = tail.split("/").filter(Boolean);
  if (parts.length >= 3) {
    const [uid, postId] = parts;
    return { uid, postId };
  }
  if (parts.length >= 2) {
    const [postId] = parts;
    return { uid: null, postId };
  }
  return null;
}
function _baMasterPath({ uid, postId }) {
  return `${BA_USER_IMG.DERIV_PREFIX}${uid ?? "null"}/${postId}/master.webp`;
}
function _baThumbURL({ uid, postId, w = 900, fmt = "webp" }) {
  return cfUrl("baUserPostThumb", { uid: uid ?? "0", post: postId, w, fmt });
}
async function _baWriteBackPostUrls({ uid, postId }) {
  if (!BA_USER_IMG.DB_WRITEBACK_ENABLED || !postId) return;
  const urls = {
    imageUrl: _baThumbURL({ uid, postId, w: 900, fmt: "webp" }),
    thumb600: _baThumbURL({ uid, postId, w: 600, fmt: "webp" }),
    thumb300: _baThumbURL({ uid, postId, w: 300, fmt: "webp" }),
    imageCdnAt: Date.now(),
  };

  // 1) Top-level: /<postId>
  try {
    const ref1 = admin.database().ref(postId);
    const s1 = await ref1.get();
    if (s1.exists()) { await ref1.update(urls); return; }
  } catch (e) { console.warn("[baWriteBack] top-level probe failed:", e?.message || e); }

  // 2) /userPosts/<uid>/<postId>
  if (uid) {
    try {
      const ref2 = admin.database().ref(`userPosts/${uid}/${postId}`);
      const s2 = await ref2.get();
      if (s2.exists()) { await ref2.update(urls); return; }
    } catch (e) { console.warn("[baWriteBack] userPosts probe failed:", e?.message || e); }
  }

  // 3) /users/<uid>/posts/<postId>
  if (uid) {
    try {
      const ref3 = admin.database().ref(`users/${uid}/posts/${postId}`);
      const s3 = await ref3.get();
      if (s3.exists()) { await ref3.update(urls); return; }
    } catch (e) { console.warn("[baWriteBack] users/.../posts probe failed:", e?.message || e); }
  }
}

// Lazily grab bucket (do NOT touch at module load in older GCF analyzers)
function _bucket() {
  return admin.storage().bucket();
}

// ---------- 1) FINALIZE TRIGGER: make master.webp (auto-orient, compressed) ----------
exports.baUserPostImageFinalize = fn.storage.object().onFinalize(async (obj) => {
  try {
    const { name, contentType } = obj || {};
    if (!name || !contentType || !BA_USER_IMG.ALLOWED_MIME.has(contentType)) return;
    const parsed = _baParseOriginalPath(name);
    if (!parsed) return;

    const bucket = _bucket();
    const src = bucket.file(name);

    // Read the original
    const [buf] = await src.download();

    // Normalize -> auto-orient + convert to webp (quality balanced for speed/size)
    const sharp = require("sharp");
    const masterBuf = await sharp(buf)
      .rotate()                     // auto-orient by EXIF
      .withMetadata({ orientation: 1 })
      .webp({ quality: 78 })
      .toBuffer();

    const masterPath = _baMasterPath(parsed);
    const masterFile = bucket.file(masterPath);

    await masterFile.save(masterBuf, {
      metadata: {
        contentType: "image/webp",
        cacheControl: `public, max-age=${BA_USER_IMG.EDGE_MAX_AGE}, s-maxage=${BA_USER_IMG.EDGE_MAX_AGE}, immutable`,
        metadata: { source: name },
      },
      resumable: false,
    });

    // Best-effort DB write-back of fast URLs
    await _baWriteBackPostUrls({ uid: parsed.uid, postId: parsed.postId });

    console.log("[baFinalize] master saved:", masterPath);
  } catch (e) {
    console.error("[baFinalize] error:", e?.message || e);
  }
});

// ---------- 2) HTTP RESIZER: serve thumbs quickly from master ----------
exports.baUserPostThumb = fn
  .runWith({ timeoutSeconds: 20, memory: "512MB" })
  .https.onRequest(async (req, res) => {
    try {
      // CORS (open)
      if (req.method === "OPTIONS") {
        res.set("Access-Control-Allow-Origin", "*");
        res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
        res.set("Access-Control-Allow-Headers", "Content-Type");
        return res.status(204).end();
      }
      res.set("Access-Control-Allow-Origin", "*");

      const uid = String(req.query.uid || "0");
      const postId = String(req.query.post || req.query.id || "").trim();
      const w = Math.max(120, Math.min(parseInt(req.query.w || "900", 10) || 900, 1600));
      const fmt = (String(req.query.fmt || "webp").toLowerCase() === "jpg" ? "jpg" : "webp");

      if (!postId) return res.status(400).send("missing ?post=");

      const bucket = _bucket();
      const masterPath = _baMasterPath({ uid: uid === "0" ? null : uid, postId });
      const file = bucket.file(masterPath);
      const [exists] = await file.exists();
      if (!exists) return res.status(404).send("master not found");

      const [buf] = await file.download();

      const sharp = require("sharp");
      let pipe = sharp(buf).resize({ width: w, withoutEnlargement: true });
      pipe = (fmt === "jpg")
        ? pipe.jpeg({ quality: 80, mozjpeg: true })
        : pipe.webp({ quality: 78 });

      const out = await pipe.toBuffer();
      res.set("Content-Type", fmt === "jpg" ? "image/jpeg" : "image/webp");
      res.set("Cache-Control", `public, max-age=${BA_USER_IMG.EDGE_MAX_AGE}, s-maxage=${BA_USER_IMG.EDGE_MAX_AGE}`);
      return res.status(200).send(out);
    } catch (e) {
      console.error("[baThumb] error:", e?.message || e);
      // Graceful transparent 1x1 (prevents broken UI)
      try {
        const sharp = require("sharp");
        const tiny = await sharp({
          create: { width: 1, height: 1, channels: 4, background: { r:0,g:0,b:0,alpha:0 } },
        }).webp({ quality: 50 }).toBuffer();
        res.set("Content-Type", "image/webp");
        res.set("Cache-Control", "no-store");
        return res.status(200).send(tiny);
      } catch {
        return res.status(500).send("thumb error");
      }
    }
  });

// ---------- 3) BACKFILL: generate master.webp + write-back URLs ----------
exports.baBackfillUserPostThumbs = fn
  .runWith({ timeoutSeconds: 180, memory: "1GB" })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method === "OPTIONS") {
        res.set("Access-Control-Allow-Origin", "*");
        res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
        res.set("Access-Control-Allow-Headers", "Content-Type");
        return res.status(204).end();
      }
      res.set("Access-Control-Allow-Origin", "*");

      // Usage:
      //   /baBackfillUserPostThumbs?post=<POST_ID>[&uid=<UID>]
      // If uid omitted, checks the "no-uid" layout only.
      const postId = String(req.query.post || req.query.id || "").trim();
      const uid = String(req.query.uid || "").trim() || null;
      if (!postId) return res.status(400).json({ ok: false, error: "missing ?post=" });

      const bucket = _bucket();
      let origPath = null;

      if (uid) {
        // Prefer with uid
        // Try to find any file under: ORIG_PREFIX/<uid>/<postId>/
        const prefix = `${BA_USER_IMG.ORIG_PREFIX}${uid}/${postId}/`;
        const [files] = await bucket.getFiles({ prefix });
        if (files.length) origPath = files.find(f => !/\/master\.webp$/i.test(f.name))?.name || files[0].name;
      } else {
        // No uid: look under ORIG_PREFIX/<postId>/
        const prefix = `${BA_USER_IMG.ORIG_PREFIX}${postId}/`;
        const [files] = await bucket.getFiles({ prefix });
        if (files.length) origPath = files.find(f => !/\/master\.webp$/i.test(f.name))?.name || files[0].name;
      }

      if (!origPath) {
        return res.json({ ok: true, postId, note: "no original found under expected prefixes" });
      }

      const parsed = _baParseOriginalPath(origPath);
      if (!parsed) return res.json({ ok: true, postId, note: "original path parse failed" });

      // Re-run finalize logic on-demand
      const src = bucket.file(origPath);
      const [buf] = await src.download();
      const sharp = require("sharp");
      const masterBuf = await sharp(buf)
        .rotate()
        .withMetadata({ orientation: 1 })
        .webp({ quality: 78 })
        .toBuffer();

      const masterPath = _baMasterPath(parsed);
      await bucket.file(masterPath).save(masterBuf, {
        metadata: {
          contentType: "image/webp",
          cacheControl: `public, max-age=${BA_USER_IMG.EDGE_MAX_AGE}, s-maxage=${BA_USER_IMG.EDGE_MAX_AGE}, immutable`,
          metadata: { source: origPath, backfill: "1" },
        },
        resumable: false,
      });

      await _baWriteBackPostUrls({ uid: parsed.uid, postId: parsed.postId });

      return res.json({
        ok: true,
        postId: parsed.postId,
        uid: parsed.uid,
        master: masterPath,
        urls: {
          imageUrl: _baThumbURL({ uid: parsed.uid, postId: parsed.postId, w: 900 }),
          thumb600: _baThumbURL({ uid: parsed.uid, postId: parsed.postId, w: 600 }),
          thumb300: _baThumbURL({ uid: parsed.uid, postId: parsed.postId, w: 300 }),
        },
      });
    } catch (e) {
      console.error("[baBackfill] error:", e?.message || e);
      return res.status(500).json({ ok: false, error: e?.message || String(e) });
    }
  });

// ---------- 4) RESOLVE: return the computed URLs for a post ----------
exports.baUserPostResolve = fn.https.onRequest(async (req, res) => {
  try {
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).end();
    }
    res.set("Access-Control-Allow-Origin", "*");

    const postId = String(req.query.post || req.query.id || "").trim();
    const uid = String(req.query.uid || "").trim() || null;
    if (!postId) return res.status(400).json({ ok: false, error: "missing ?post=" });

    return res.json({
      ok: true,
      postId,
      uid: uid || null,
      imageUrl: _baThumbURL({ uid, postId, w: 900 }),
      thumb600: _baThumbURL({ uid, postId, w: 600 }),
      thumb300: _baThumbURL({ uid, postId, w: 300 }),
    });
  } catch (e) {
    return res.status(500).json({ ok: false, error: e?.message || String(e) });
  }
});


// === 🔍 Root probe — lists a few root keys and their child field names (for verification)
exports.baRootKeysProbe = fn.https.onRequest(async (req, res) => {
  try {
    const limit = Math.max(5, Math.min(parseInt(req.query.limit || "30", 10) || 30, 200));
    const start = String(req.query.start || "") || null;

    const SKIP = new Set([
      "activityLogs","admins","brands","directChats","gossip","groups","promoterApplications","promoters",
      "purchaseIntents","purchases","rssCache","savedProducts","supportMessages","users","venueApplications",
      "venues","xnews","gossipRss","gossipRSS","_meta","_health","health","settings","__debug"
    ]);

    const out = [];
    let cursor = start || "";
    const rootRef = rtdb.ref("/");
    let scanned = 0;

    while (out.length < limit) {
      const snap = cursor
        ? await rootRef.orderByKey().startAt(cursor).limitToFirst(200).get()
        : await rootRef.orderByKey().limitToFirst(200).get();

      const obj = snap.val() || {};
      const keys = Object.keys(obj).sort();
      if (!keys.length) break;

      for (const k of keys) {
        cursor = k;
        if (SKIP.has(k)) continue;
        scanned++;
        const cs = await rtdb.ref(k).get().catch(() => null);
        const v = cs?.val();
        out.push({
          key: k,
          type: typeof v,
          isObject: v && typeof v === "object" && !Array.isArray(v),
          fieldCount: v && typeof v === "object" ? Object.keys(v).length : 0,
          sampleFields: v && typeof v === "object" ? Object.keys(v).slice(0, 15) : [],
        });
        if (out.length >= limit) break;
      }

      cursor = cursor + "\uf8ff";
      if (out.length >= limit) break;
    }

    res.status(200).json({ ok: true, scanned, listed: out.length, next: out.length ? { start: out[out.length - 1].key } : null, items: out });
  } catch (e) {
    res.status(500).json({ ok: false, error: e?.message || String(e) });
  }
});


// === 🔁 Block P1 — Backfill thumbs for /posts (paginated, liberal media detection) ===
exports.baPostsProbe = fn.https.onRequest(async (req, res) => {
  try {
    const limit = Math.max(5, Math.min(parseInt(req.query.limit || "30", 10) || 30, 500));
    const start = (req.query.start && String(req.query.start)) || null;

    const ref = rtdb.ref("posts");
    const snap = start
      ? await ref.orderByKey().startAt(start).limitToFirst(limit).get()
      : await ref.orderByKey().limitToFirst(limit).get();

    const obj = snap.val() || {};
    const keys = Object.keys(obj);
    const items = keys.map(k => {
      const v = obj[k] || {};
      return {
        key: k,
        hasThumb: !!(v.thumb || v.thumbUrl),
        mediaHints: Object.keys(v).filter(x =>
          /image|photo|media|url|path|storage|cover|thumbnail|thumb/i.test(x)
        ).slice(0, 15),
      };
    });

    const next = keys.length ? { start: keys[keys.length - 1] + "\uf8ff" } : null;

    res.status(200).json({ ok: true, listed: keys.length, next, items });
  } catch (e) {
    res.status(500).json({ ok: false, error: e?.message || String(e) });
  }
});



// Image resize proxy with smarter contain/cover behavior:
// - NEW: mode=fluid (default) → no-crop, no padding, height computed from source aspect
// - mode=canvas → fixed WxH canvas; use fit=contain|cover|inside|fillmax; bg color applied
// - fit=fillmax: if aspect delta ≤ 10%, use cover (minimal crop), else contain (no crop)
// - ar=auto honors source aspect (when mode=fluid or when computing H)
// - fmt=webp|jpg; default webp
exports.imgThumb = fn.https.onRequest(async (req, res) => {
  try {
    const srcUrl = String(q(req, "url") || "");
    const fmt = String(q(req, "fmt") || "webp").toLowerCase();             // webp | jpg | jpeg
    const w   = Math.max(120, Math.min(Number(q(req, "w")) || 900, 2000)); // target width

    // Default to "fluid" so images don't end up as tiny postcards in a fixed canvas.
    // In fluid mode: we compute height from the source aspect (no padding, no crop).
    const mode = (q(req, "mode") || "fluid").toLowerCase();                // fluid | canvas

    // When mode=canvas, you can still pass a strict height (h) or aspect (ar).
    // If ar=auto, we’ll compute H from source aspect as best as possible.
    const arStr = String(q(req, "ar") || "16:9").toLowerCase();            // e.g., "auto", "1:1", "4:5", "16:9"
    const fitReq = (q(req, "fit") || (mode === "canvas" ? "contain" : "contain")).toLowerCase();
    const bgParam = q(req, "bg");
    const bgColor =
      (bgParam && bgParam.toLowerCase() === "transparent")
        ? { r: 0, g: 0, b: 0, alpha: 0 }
        : (bgParam || "#ffffff"); // default white for nicer letterbox in light UIs

    // Fallback logo control (still centered, 25% width by default)
    const fallbackUrl = String(q(req, "fallback") || getLogoFallback() || FALLBACK_LOGO || "");
    const fallbackScale = Math.max(0.05, Math.min(Number(q(req, "fallbackScale")) || 0.25, 0.9));

    // Hard upstream timeout to keep UI snappy
    const HARD_MS = 1400;
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), HARD_MS);

    const setCT = () => res.set("Content-Type", (fmt === "jpg" || fmt === "jpeg") ? "image/jpeg" : "image/webp");
    const cacheReal = () => res.set("Cache-Control", "public, max-age=86400, s-maxage=86400, stale-while-revalidate=60, stale-if-error=600");
    const cacheFallback = () => res.set("Cache-Control", "no-store, must-revalidate");

    // --- Load upstream (if any) ---
    let upstreamBuf = null;
    try {
      if (/^https?:\/\//i.test(srcUrl)) {
        const upstream = await undiciFetch(srcUrl, { redirect: "follow", signal: ac.signal });
        if (upstream && upstream.ok) upstreamBuf = Buffer.from(await upstream.arrayBuffer());
      }
    } catch (_) {
      // ignore; we’ll render fallback below
    } finally {
      clearTimeout(t);
    }

    // Utility to parse "W:H"
    function parseAR(s) {
      if (!s || s === "auto") return null;
      const m = s.split(":").map(Number);
      if (m.length === 2 && m[0] > 0 && m[1] > 0) return { aw: m[0], ah: m[1] };
      return null;
    }
    const arPair = parseAR(arStr);

    // Compute a target height when we need a canvas
    function targetHFromAR() {
      if (arPair) return Math.max(80, Math.round(w * (arPair.ah / arPair.aw)));
      // default to 16:9 if we must create a canvas without source metadata
      return Math.max(80, Math.round(w * 9 / 16));
    }

async function renderShrunkFallback(hHint) {
  // Compute a fixed canvas height using requested AR (or default 16:9)
  const H = Math.max(80, hHint || targetHFromAR());

  // Try to fetch the fallback logo (if configured)
  let fbBuf = null;
  if (fallbackUrl) {
    try {
      const fbResp = await undiciFetch(fallbackUrl, { redirect: "follow" });
      if (fbResp && fbResp.ok) fbBuf = Buffer.from(await fbResp.arrayBuffer());
    } catch {}
  }

  // Always produce a fixed canvas (mode=canvas behavior for fallback),
  // so the logo size is relative to the canvas, not to the source.
  const canvas = sharp({
    create: {
      width: w,
      height: H,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 1 },

    },
  });

  let out;
  if (fbBuf) {
    // Scale the logo to 25% (or fallbackScale) of the SHORTER canvas side,
    // so it is visually consistent in both landscape and portrait tiles.
    const innerEdge = Math.max(40, Math.round(Math.min(w, H) * fallbackScale));
    const logoBuf = await sharp(fbBuf)
      .resize({ width: innerEdge, height: innerEdge, fit: "inside", withoutEnlargement: true })
      .toBuffer();

    out = await canvas
      .composite([{ input: logoBuf, gravity: "center" }])
      .toFormat((fmt === "jpg" || fmt === "jpeg") ? "jpeg" : "webp", { quality: 80 })
      .toBuffer();
  } else {
    // No logo available; return a clean blank tile
    out = await canvas
      .toFormat((fmt === "jpg" || fmt === "jpeg") ? "jpeg" : "webp", { quality: 80 })
      .toBuffer();
  }

  cacheFallback(); setCT();
  res.set("X-Thumb-Status", "fallback-canvas-25p");
  res.set("Retry-After", "5");
  return res.status(200).send(out);
}


    // If no upstream, render fallback
    if (!upstreamBuf) return await renderShrunkFallback(null);

    // --- We have upstream: read metadata to decide layout smartly ---
    let meta;
    try { meta = await sharp(upstreamBuf).metadata(); } catch { meta = {}; }
    const sw = Math.max(1, Number(meta.width || 0));
    const sh = Math.max(1, Number(meta.height || 0));
    const sAspect = sw / sh;

    // Compute canvas H if we need one
    let H = arPair ? Math.max(80, Math.round(w * (arPair.ah / arPair.aw))) : null;

    // "fillmax" decision: cover only when aspect close enough (<=10% delta)
    function pickFit(fitRequested) {
      if (fitRequested !== "fillmax") return fitRequested;
      const targetAspect = arPair ? (arPair.aw / arPair.ah) : sAspect;
      const delta = Math.abs(sAspect - targetAspect) / targetAspect; // relative diff
      return (delta <= 0.10) ? "cover" : "contain";
    }

    const finalFit = pickFit(fitReq);

    // ==========
    // MODE: FLUID (default) → no crop, no padding, variable height
    // ==========
    if (mode === "fluid") {
      // Height driven by source aspect (or best effort)
      const autoH = Math.max(80, Math.round(w / (sAspect || (16 / 9))));
      let pipe = sharp(upstreamBuf).rotate(); // auto-orient
      // Resize by width only (no forced height == no padding, no crop)
      pipe = pipe.resize({ width: w, withoutEnlargement: false });
      if (fmt === "jpg" || fmt === "jpeg") {
        pipe = pipe.jpeg({ quality: 82, mozjpeg: true });
      } else {
        pipe = pipe.webp({ quality: 80 });
      }
      const out = await pipe.toBuffer();
      cacheReal(); setCT();
      res.set("X-Thumb-Status", "real-fluid");
      // Helpful hint for clients that rely on layout sizing
      res.set("X-Image-Height", String(autoH));
      return res.status(200).send(out);
    }

    // ==========
    // MODE: CANVAS (fixed WxH) → may letterbox/pillarbox or crop
    // ==========
    const canvasH = H || targetHFromAR();
    let pipe = sharp(upstreamBuf).rotate(); // auto-orient

    // Map our fits to sharp options
    const sharpFit =
      finalFit === "contain" ? "contain" :
      finalFit === "cover"   ? "cover"   :
      finalFit === "inside"  ? "inside"  :
      "contain";

    pipe = pipe.resize({
      width: w,
      height: canvasH,
      fit: sharpFit,
      position: "center",
      background: { r: 0, g: 0, b: 0, alpha: 1 },
      withoutEnlargement: false,
    });

    if (fmt === "jpg" || fmt === "jpeg") {
      pipe = pipe.jpeg({ quality: 82, mozjpeg: true });
    } else {
      pipe = pipe.webp({ quality: 80 });
    }

    const out = await pipe.toBuffer();
    cacheReal(); setCT();
    res.set("X-Thumb-Status", `real-canvas-${finalFit}`);
    return res.status(200).send(out);

  } catch (e) {
    console.error("imgThumb error", e);
    try {
      const w = 900, h = Math.round(900 * 9 / 16);
      const out = await sharp({ create: { width: w, height: h, channels: 4, background: "#ffffff" } })
        .webp({ quality: 78 }).toBuffer();
      res.set("Content-Type", "image/webp");
      res.set("Cache-Control", "no-store, must-revalidate");
      res.set("X-Thumb-Status", "fallback-hard");
      return res.status(200).send(out);
    } catch {
      return res.status(500).send("thumb error");
    }
  }
});

// TUNED: write thumbs as JPEG + contain + solid bg by default
exports.baBackfillPosts = fn.https.onRequest(async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS, GET");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  try {
    const isPost = req.method === "POST";
    const body = isPost ? (typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {})) : {};

    const limit = Math.max(1, Math.min(parseInt(body.limit || "200", 10) || 200, 5000));
    const batchSize = Math.max(10, Math.min(parseInt(body.batchSize || "200", 10) || 200, 1000));
    const thumbWidth = Math.max(120, Math.min(parseInt(body.thumbWidth || "900", 10) || 900, 2000));
    const force = String(body.force || "0") === "1";
    const onlyMissing = String(body.onlyMissing ?? "1") === "1";
    const dry = String(body.dry || "1") === "1";

    // Visual defaults for iOS safety
    const bg = encodeURIComponent(String(body.bg || "#111111"));
    const extra = String(body.thumbParams || "fit=contain&ar=auto&fmt=jpg&bg=" + bg);

    const fallback = getLogoFallback();
    const scanned = [];
    const sample = [];
    let wroteBack = 0;

    const hasUrlParam = (u) => { try { return new URL(u).searchParams.has("url"); } catch { return false; } };
    const ensureHttps = (u) => { try { const x = new URL(String(u)); if (x.protocol === "http:") x.protocol = "https:"; return x.toString(); } catch { return null; } };

    function pickFirstUrlish(v) {
      const arr = Array.isArray(v) ? v : [];
      for (const e of arr) {
        const u = ensureHttps(e && (e.url || e.src || e));
        if (u && /^https?:\/\//i.test(u)) return u;
      }
      return null;
    }

    async function signGsUrlMaybe(raw) {
      if (!raw) return null;
      if (/^https?:\/\//i.test(raw)) return raw;
      try {
        let bucket = admin.storage().bucket();
        let filePath = null;
        if (/^gs:\/\//i.test(raw)) {
          const m = raw.match(/^gs:\/\/([^/]+)\/(.+)$/i);
          if (m) { bucket = admin.storage().bucket(m[1]); filePath = m[2]; }
        } else if (raw.startsWith("/")) filePath = raw.replace(/^\/+/, "");
        else filePath = raw;

        if (!filePath) return null;
        const [exists] = await bucket.file(filePath).exists();
        if (!exists) return null;
        const [url] = await bucket.file(filePath).getSignedUrl({ action: "read", expires: Date.now() + 1000*60*60*6 });
        return ensureHttps(url);
      } catch { return null; }
    }

    async function detectSource(v) {
      const candidates = [
        v.imageURL, v.imageUrl, v.image, v.photoURL, v.photoUrl,
        v.mediaURL, v.mediaUrl, v.mediaRawUrl,
        (v.media && (v.media.url || v.media.src)),
        pickFirstUrlish(v.images),
        pickFirstUrlish(v.thumbnails),
        v.thumbnailURL, v.videoThumb,
      ].filter(Boolean);

      for (const c of candidates) {
        const https = ensureHttps(c);
        if (https && /^https?:\/\//i.test(https)) return https;
        if (https && /^gs:\/\//i.test(https)) {
          const signed = await signGsUrlMaybe(https);
          if (signed) return signed;
        }
      }
      if (typeof v.path === "string" && v.path.trim()) {
        const signed = await signGsUrlMaybe(v.path.trim());
        if (signed) return signed;
      }
      return null;
    }

    const postsRef = rtdb.ref("posts");
    const snap = await postsRef.limitToFirst(limit).get();
    if (!snap.exists()) return res.json({ ok: true, dry, scanned: 0, wroteBack: 0, next: null, sample: [] });

    const updates = {};
    let inBatch = 0;
    const flush = async () => { if (!inBatch) return; if (!dry) await rtdb.ref().update(updates); inBatch = 0; for (const k of Object.keys(updates)) delete updates[k]; };

    const children = []; snap.forEach(cs => children.push(cs));

    for (const cs of children) {
      const postId = cs.key;
      const v = cs.val() || {};
      scanned.push(postId);

      try {
        const existing = typeof v.thumb === "string" ? v.thumb : "";
        const needReplaceBecauseMissing = !existing || !hasUrlParam(existing);
        const shouldRewrite = force || needReplaceBecauseMissing || (!onlyMissing);

        if (!shouldRewrite) { sample.length < 12 && sample.push({ postId, ok: true, note: "already-normalized" }); continue; }

        const src = await detectSource(v);
        const srcPresent = !!src;

        const thumbUrl =
          cfUrl("imgThumb", {
            url: src || "",
            w: thumbWidth,
            fallback,
            fallbackScale: 0.25,
          }) + (extra ? `&${extra}` : "");

        updates[`posts/${postId}/thumb`] = thumbUrl;
        wroteBack++; inBatch++;
        sample.length < 12 && sample.push({ postId, ok: true, thumb: thumbUrl, srcPresent });

        if (inBatch >= batchSize) await flush();
      } catch (e) {
        sample.length < 12 && sample.push({ postId, ok: false, error: String(e?.message || e) });
      }
    }

    await flush();

    return res.json({ ok: true, dry, scanned: scanned.length, wroteBack, next: null, sample });
  } catch (e) {
    console.error("baBackfillPosts error:", e);
    return res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});


// Paged & Chunked Recent Posts Sweeper (avoids TRIGGER_PAYLOAD_TOO_LARGE)
const SWEEP_LIMIT_DEFAULT = 150;          // default page size (safe)
const SWEEP_WRITE_BATCH = 75;             // max keys per multi-update
const PROBE_CONCURRENCY = 12;             // parallel HEAD/GETs
const SWEEP_THUMB_W = 900;
const SWEEP_THUMB_PARAMS = "mode=canvas&ar=16:9&fit=fillmax&bg=%23000000";

// tiny async pool
async function _pool(limit, items, worker) {
  const ret = [];
  const running = new Set();
  for (const it of items) {
    const p = Promise.resolve().then(() => worker(it))
      .then((r) => ret.push(r))
      .catch(() => {}) // swallow per-item probe errs
      .finally(() => running.delete(p));
    running.add(p);
    if (running.size >= limit) await Promise.race(running);
  }
  if (running.size) await Promise.allSettled([...running]);
  return ret;
}

function _pickSrc(v = {}) {
  const cands = [
    v.mediaRawUrl, v.mediaURL, v.imageURL, v.image, v.media?.url, v.media
  ].map(x => (x ? String(x) : "")).filter(Boolean);
  for (const c of cands) {
    try { const u = new URL(c); u.protocol = "https:"; return u.toString(); } catch {}
  }
  return null;
}

function _mkThumb(srcUrl, w = SWEEP_THUMB_W, params = SWEEP_THUMB_PARAMS, cb = (Date.now()/1000)|0) {
  const u = new URL(cfUrl("imgThumb", {
    url: srcUrl || "",
    w,
    fallback: getLogoFallback(),
    fallbackScale: 0.25,
  }));
  const p = new URLSearchParams(params);
  for (const [k, v] of p) u.searchParams.set(k, v);
  u.searchParams.set("cb", String(cb)); // cache buster
  return u.toString();
}

async function _probe(url, timeoutMs = 1200) {
  if (!url) return false;
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), timeoutMs);
  try {
    let r = await undiciFetch(url, { method: "HEAD", redirect: "follow", signal: ac.signal });
    if (r.ok) return true;
    r = await undiciFetch(url, { method: "GET", redirect: "follow", signal: ac.signal });
    return r.ok;
  } catch {
    return false;
  } finally { clearTimeout(t); }
}

// HTTPS (manual) — POST JSON: { limit?:number, start?:string, dry?:0|1 }
exports.baSweepRecentPostsNow = fn.https.onRequest(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    const limit = Math.max(1, Math.min(parseInt(body.limit || SWEEP_LIMIT_DEFAULT, 10) || SWEEP_LIMIT_DEFAULT, 500));
    const dry = String(body.dry || "0") === "1";
    const start = (body.start && String(body.start)) || null;

    // page: newest-first using limitToLast; for pagination, we use orderByKey startAt
    let ref = rtdb.ref("posts").orderByKey();
    if (start) ref = ref.startAt(start);
    ref = ref.limitToFirst(limit);

    const snap = await ref.get();
    if (!snap.exists()) {
      return res.json({ ok: true, scanned: 0, wrote: 0, next: null, dry });
    }

    const rows = [];
    snap.forEach(ch => rows.push({ id: ch.key, val: ch.val() || {} }));

    // Work each row with bounded concurrency
    const pending = await _pool(PROBE_CONCURRENCY, rows, async ({ id, val }) => {
      const src = _pickSrc(val);
      const thumb = typeof val.thumb === "string" ? val.thumb : "";
      if (!src && !thumb) return null;                // nothing to do
      if (thumb) {
        const ok = await _probe(thumb).catch(() => false);
        if (ok) return null;                          // good thumb
      }
      if (!src) return null;                          // no way to remake
      return { id, newThumb: _mkThumb(src) };
    });

    // Filter and batch the writes
    const writes = pending.filter(Boolean);
    let wrote = 0;
    if (!dry && writes.length) {
      for (let i = 0; i < writes.length; i += SWEEP_WRITE_BATCH) {
        const chunk = writes.slice(i, i + SWEEP_WRITE_BATCH);
        const up = {};
        for (const w of chunk) up[`posts/${w.id}/thumb`] = w.newThumb;
        await rtdb.ref().update(up);
        wrote += chunk.length;
      }
    } else {
      wrote = writes.length;
    }

    // Compute next cursor (last key in this page, then client will pass it back)
    const nextStart = rows.length ? rows[rows.length - 1].id : null;

    // small sample for visibility
    const sample = writes.slice(0, 12).map(w => ({ id: w.id, thumb: w.newThumb.slice(0, 160) + "..." }));

    return res.json({
      ok: true,
      dry,
      scanned: rows.length,
      wrote,
      next: nextStart ? { start: nextStart } : null,
      sample
    });
  } catch (e) {
    return res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});



// === Gossip Top-Refresh (backend-assisted, throttle, ETag, 304) ===
// Call this when user scrolls to top. It returns cached items fast, and
// quietly nudges the backend to refresh if the cache is stale. No client
// "pull-to-refresh" needed; this handles throttling and conditional 304s.
//
// GET /gossipTopRefresh?gesture=top
// Optional: send "If-None-Match" header; we'll return 304 Not Modified when unchanged.
// Optional: header "x-uid: <uid>" to get per-user throttle; else we derive from IP+UA.

exports.gossipTopRefresh = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type, If-None-Match, x-uid, x-forwarded-for, user-agent");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  // --- Tunables ---
  const CACHE_NODE    = "gossip/rssCache/latest"; // where rssBundle already writes
  const STALE_MS      = 90 * 1000;                // consider cache stale after 90s
  const GEST_TTL_MS   = 20 * 1000;                // per-client gesture throttle: 20s
  const REFRESH_DEADLINE_MS = 2500;               // time budget for kick (non-blocking)

  const now = Date.now();
  const gestureTop = String(q(req, "gesture") || "") === "top";

  // Build a stable per-client key for throttle
  function clientKeyFromReq() {
    const uid = (req.get("x-uid") || "").trim();
    if (uid) return `uid:${uid}`;
    // Hash of IP + UA
    const ip = (req.headers["x-forwarded-for"] || req.socket?.remoteAddress || "").toString().split(",")[0].trim();
    const ua = (req.get("user-agent") || "").slice(0,160);
    const key = crypto.createHash("sha1").update(`${ip}|${ua}`).digest("hex").slice(0,20);
    return `hash:${key}`;
  }
  const clientKey = clientKeyFromReq();

  // Load current cache
  let cache = null;
  try {
    const snap = await rtdb.ref(CACHE_NODE).get();
    if (snap.exists()) cache = snap.val() || null;
  } catch (e) {
    console.warn("[gossipTopRefresh] cache read error:", e?.message || e);
  }

  const savedAt = Number(cache?.savedAt || 0);
  const items   = Array.isArray(cache?.items) ? cache.items : [];
  const count   = Number(cache?.count || (Array.isArray(items) ? items.length : 0));
  const etag    = `"${savedAt}:${count}"`; // weak-enough ETag for UI diffing

  // Conditional GET: if client has the same ETag, 304
  const inm = req.get("If-None-Match");
  if (inm && inm === etag) {
    res.set("ETag", etag);
    res.set("Cache-Control", "no-store, must-revalidate");
    return res.status(304).end();
  }

  // Possibly honor refresh hint (scroll-to-top), throttled
  let throttled = false;
  let kicked = false;

  if (gestureTop) {
    try {
      const kRef = rtdb.ref(`metrics/gossipGesture/${clientKey}`);
      const lastSnap = await kRef.get();
      const last = Number(lastSnap.val() || 0);
      if (!last || now - last >= GEST_TTL_MS) {
        await kRef.set(now);
        // If the cache is stale, fire-and-forget a refresh (do not await)
        if (!savedAt || now - savedAt >= STALE_MS) {
          kicked = true;
          const refreshUrl = cfUrl("rssBundle", {
            perFeedLimit: 6,
            thumbWidth: 900,
            cache: 1
          });
          const ac = new AbortController();
          const t  = setTimeout(() => ac.abort(), REFRESH_DEADLINE_MS);
          undiciFetch(refreshUrl, { method: "POST", signal: ac.signal, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ feeds: [] }) })
            .catch((e) => console.warn("[gossipTopRefresh] refresh kick failed:", e?.message || e))
            .finally(() => clearTimeout(t));
        }
      } else {
        throttled = true;
      }
    } catch (e) {
      console.warn("[gossipTopRefresh] throttle error:", e?.message || e);
    }
  } else {
    // No gesture: optionally kick if cache is very old (e.g., > 5 min)
    if (!savedAt || now - savedAt > 5 * 60 * 1000) {
      try {
        const refreshUrl = cfUrl("rssBundle", { perFeedLimit: 6, thumbWidth: 900, cache: 1 });
        const ac = new AbortController();
        const t  = setTimeout(() => ac.abort(), REFRESH_DEADLINE_MS);
        undiciFetch(refreshUrl, { method: "POST", signal: ac.signal, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ feeds: [] }) })
          .catch(() => {})
          .finally(() => clearTimeout(t));
      } catch {}
    }
  }

  // Safety: if no cache yet, return empty with hint
  if (!cache) {
    res.set("ETag", `"0:0"`);
    res.set("Cache-Control", "no-store, must-revalidate");
    return res.status(200).json({ ok: true, items: [], count: 0, serverTs: 0, fromCache: true, refreshing: kicked, throttled });
  }

  // Normal response: serve cache immediately
  res.set("ETag", etag);
  // Let the browser/app avoid re-fetching excessively while we control freshness with gesture & kicks:
  res.set("Cache-Control", "public, max-age=20, stale-while-revalidate=30");
  return res.status(200).json({
    ok: true,
    count,
    serverTs: savedAt,
    fromCache: true,
    refreshing: kicked,
    throttled,
    items
  });
});

// --- BEGIN Block H: rssBundleLite with debug + gesture=top throttle ---
exports.rssBundleLite = fn
  .runWith({ timeoutSeconds: 10, memory: "256MB" })
  .https.onRequest(async (req, res) => {
    // CORS
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      return res.status(204).end();
    }
    res.set("Access-Control-Allow-Origin", "*");

    try {
      const debug = String(req.query.debug || req.body?.debug || "0") === "1";
      const force = String(req.query.force || req.body?.force || "0") === "1";
      const gesture = String(req.query.gesture || req.body?.gesture || "").toLowerCase(); // "top" | ""
      const HARD_DEADLINE_MS = 8000;
      const started = Date.now();
      const now = Date.now();
      const staleSeconds = 90; // threshold for background refresh

      // Helper: read cached bundle
      async function readCache() {
        const snap = await rtdb.ref("gossip/rssCache/latest").get();
        if (!snap.exists()) return { savedAt: 0, items: [] };
        const j = snap.val() || {};
        const savedAt = Number(j.savedAt || 0);
        const items = Array.isArray(j.items) ? j.items : [];
        return { savedAt, items, count: Number(j.count || items.length || 0) };
      }

      // Helper: quickly trigger refresh in background (fire-and-forget)
      async function triggerRefresh(reason) {
        try {
          const url = cfUrl("rssBundle");
          const ctrl = new AbortController();
          const t = setTimeout(() => ctrl.abort(), 1200);
          // Minimal body that asks rssBundle to refresh cache
          const body = JSON.stringify({
            feeds: [],            // rssBundle will still merge IG + saved feeds if configured
            perFeedLimit: 6,
            thumbWidth: 900,
            cache: 1              // write-through cache (default path in your rssBundle)
          });
          // Fire & forget; we don't await completion, just kick it off.
          fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body, signal: ctrl.signal })
            .catch(() => null)
            .finally(() => clearTimeout(t));

          // Record an audit ping (best-effort)
          rtdb.ref("metrics/gossip/touches").push({
            at: admin.database.ServerValue.TIMESTAMP,
            reason,
            gesture: gesture || null,
          }).catch(() => null);

          return true;
        } catch { return false; }
      }

      const cache = await readCache();
      const ageSec = cache.savedAt ? Math.max(0, Math.floor((now - cache.savedAt) / 1000)) : null;
      const isStale = force ? true : (ageSec == null ? true : ageSec >= staleSeconds);

      let refreshTriggered = false;
      let refreshReason = null;

      // Decide when to kick off background refresh
      if (force) {
        refreshReason = "force";
        refreshTriggered = await triggerRefresh(refreshReason);
      } else if (gesture === "top" && isStale) {
        // Treat scroll-to-top as a refresh signal, but only if stale
        refreshReason = "gesture_top_stale";
        refreshTriggered = await triggerRefresh(refreshReason);
      } else if (!cache.items?.length) {
        refreshReason = "empty_cache";
        refreshTriggered = await triggerRefresh(refreshReason);
      }

      // Build response
      const rid = Math.random().toString(36).slice(2, 8);
      res.set("X-Gossip-Request", rid);
      res.set("X-Gossip-Cache-Age", String(ageSec ?? -1));
      res.set("X-Gossip-Refresh", refreshTriggered ? "triggered" : "none");

      const payload = {
        ok: true,
        // Always return the (possibly stale) cached items immediately so UI never stalls
        items: cache.items || [],
        _meta: debug ? {
          requestId: rid,
          timeMs: Date.now() - started,
          cache: {
            savedAt: cache.savedAt || 0,
            ageSec: ageSec,
            count: cache.count || (cache.items?.length || 0),
          },
          refresh: {
            consideredStale: !!isStale,
            triggered: !!refreshTriggered,
            reason: refreshReason,
          },
          notes: [
            "Returns cached items synchronously.",
            "If stale or forced, a background refresh is kicked off.",
            "Call again after ~2–3s (or on next scroll-to-top) to see new cache."
          ]
        } : undefined
      };

      return res.status(200).json(payload);
    } catch (e) {
      console.error("[rssBundleLite] error:", e);
      return res.status(500).json({ ok: false, error: String(e?.message || e) });
    }
  });
// --- END Block H ---


// --- BEGIN Block I: probeThumb (image/thumbnail diagnostics) ---
exports.probeThumb = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const url = String(req.query.url || "").trim();
    if (!/^https?:\/\//i.test(url)) {
      return res.status(400).json({ ok: false, error: "Provide ?url=https..." });
    }

    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 3000);
    let r;
    try {
      // Try HEAD first; fall back to GET for servers that don't support HEAD
      r = await fetch(url, { method: "HEAD", signal: ac.signal });
      if (!r.ok || !r.headers?.get) {
        r = await fetch(url, { method: "GET", signal: ac.signal });
      }
    } finally { clearTimeout(t); }

    const ct = r.headers?.get("content-type") || "";
    const len = Number(r.headers?.get("content-length") || 0);
    const xts = r.headers?.get("x-thumb-status") || ""; // our imgThumb returns 'real' | 'fallback'

    return res.json({
      ok: true,
      url,
      status: r.status,
      contentType: ct,
      contentLength: isFinite(len) ? len : null,
      xThumbStatus: xts || null,
      cacheControl: r.headers?.get("cache-control") || null,
      note: "If xThumbStatus=fallback and content-length is small, upstream likely failed/slow; our 25% logo was used."
    });
  } catch (e) {
    return res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});
// --- END Block I ---


// ============ AI BlackApp Crew (no-API scrapers) ============
// Scans public webpages you configure per city → extracts nightlife cards
// → uploads flyer → writes posts to /gossip/posts with #City tag
// Schedule: hourly. Also supports HTTPS for manual runs, debug mode, and a bucket diagnostic.
//
// RTDB config path: /gossip/aiCrew/cities
// Example city keys: CLT, ATL, LOS, LON, etc.
//
// Deps (from functions/):
//   npm i cheerio node-fetch@2 abort-controller

const cheerio = require("cheerio");

// ---- Admin init (prefer the newer firebasestorage.app bucket) ----
const PREFERRED_BUCKET = `${PROJECT_ID}.firebasestorage.app`; // matches your console
const FALLBACK_BUCKET  = `${PROJECT_ID}.appspot.com`;          // classic default
const BUCKET_NAME = PREFERRED_BUCKET; // use the preferred one for your project

try {
  admin.app();
} catch {
  admin.initializeApp({
    storageBucket: BUCKET_NAME,
    databaseURL: "https://blackappios-default-rtdb.firebaseio.com"
  });
}

const storage = admin.storage().bucket(BUCKET_NAME); // explicit bucket pin

const LOGO_URL = "https://blackapp.io/images/blackapp-logo.png";
const MAX_POSTS_PER_CITY_PER_RUN = 6;
const MIN_IMAGE_WIDTH = 300;

const KEYWORDS = [
  // core Afro/urban
  "afrobeats","afrobeat","amapiano","afro house","afrohouse",
  "hip-hop","hip hop","trap","r&b","dancehall","soca",
  "afro pop","afropop","naija","afro vibes","afro nights",
  // nightlife signals
  "nightlife","club","lounge","party","day party","brunch party","after party",
  "dj","rave","hookah","ladies night","open bar","ticket","guest list"
];

const MONTH_WORDS = [
  "january","february","march","april","may","june",
  "july","august","september","october","november","december"
];

// ---------- Utils ----------
function sha1(s) {
  return crypto.createHash("sha1").update(String(s)).digest("hex");
}

function pickBestText(...cands) {
  return cands.filter(Boolean).map(t => String(t).trim()).find(t => t.length >= 5);
}

function stripHtml(s) {
  return String(s || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
}

function looksNightlifey(text) {
  const s = (text || "").toLowerCase();
  return KEYWORDS.some(k => s.includes(k));
}

function isLikelyLogoUrl(u = "") {
  const l = u.toLowerCase();
  return (
    l.includes("logo") ||
    l.includes("favicon") ||
    l.includes("sprite") ||
    l.includes("placeholder") ||
    l.endsWith("/logo.png") ||
    l.endsWith("/logo.jpg") ||
    /\blogo[-_.]/.test(l)
  );
}

// Filter out headings / category labels that aren't real events
function isJunkyTitle(t) {
  const s = (t || "").trim();
  if (!s) return true;
  const l = s.toLowerCase();

  // "1. October" / numbered list headings
  if (/^\d+\.\s*\w+/.test(s)) return true;

  // Pure month or common category headers
  if (MONTH_WORDS.some(m => l === m || l.startsWith(m + " "))) return true;
  if (/(events|things to do|free events|live concerts|halloween events|oktoberfest)$/i.test(s)) return true;

  // Very short or generic
  if (s.length < 6) return true;

  return false;
}

// Accept if: (a) genre matches OR (b) title is not junk and image looks like a flyer
function isAcceptableCard({ title, link, imgUrl }) {
  if (isJunkyTitle(title)) return false;
  if (isLikelyLogoUrl(imgUrl)) return false;
  const t = `${title || ""} ${link || ""}`.toLowerCase();
  const hasGoodImg = !!imgUrl && /\.(jpg|jpeg|png|webp|gif)/i.test(imgUrl);
  const longEnough = (title || "").trim().length >= 10;
  return looksNightlifey(t) || (hasGoodImg && longEnough);
}

function absolutize(url, base) {
  if (!url) return url;
  if (/^https?:\/\//i.test(url)) return url;
  try {
    const b = new URL(base);
    if (url.startsWith("//")) return `${b.protocol}${url}`;
    if (url.startsWith("/")) return `${b.origin}${url}`;
    return `${b.origin}/${url.replace(/^\.\//, "")}`;
  } catch {
    return url;
  }
}

async function fetchWithTimeout(url, { timeoutMs = 20000, headers = {} } = {}) {
  const AbortController = require("abort-controller");
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    return await fetch(url, {
      headers: {
        "User-Agent": "Mozilla/5.0",
        "Accept-Language": "en-US,en;q=0.9",
        ...headers
      },
      redirect: "follow",
      signal: ctl.signal
    });
  } finally {
    clearTimeout(t);
  }
}

// ---------- HTML → cards ----------
function extractCards(html, baseUrl) {
  const $ = cheerio.load(html);
  const cards = [];
  const baseHost = (() => { try { return new URL(baseUrl).hostname; } catch { return ""; } })();

  // A) OG first (helps featured items + single pages)
  const ogTitleRaw = $('meta[property="og:title"]').attr("content");
  const ogImg = $('meta[property="og:image"]').attr("content");
  const ogTitle = stripHtml(ogTitleRaw);
  if (ogTitle && ogImg && !isJunkyTitle(ogTitle) && !isLikelyLogoUrl(ogImg)) {
    cards.push({ title: ogTitle, link: baseUrl, img: ogImg, width: MIN_IMAGE_WIDTH });
  }

  // B) Domain-aware selectors (Eventbrite-like listing cards)
  const perDomainSelectors = [];
  if (baseHost.includes("eventbrite.")) {
    perDomainSelectors.push(
      'a[data-spec="event-card__formatted-name--content"]',
      '[data-spec="event-card__body"] a'
    );
  }

  // C) Generic selectors
  const genericSelectors = [
    "article a",
    ".event a", ".listing a", ".card a", ".media a", ".post a",
    ".teaser a", ".grid-item a", ".tile a", ".entry a", ".event-card a", ".event-item a",
    "h1 a", "h2 a", "h3 a", "a:has(img)"
  ];
  const selectors = [...perDomainSelectors, ...genericSelectors];

  $(selectors.join(",")).each((_, a) => {
    const $a = $(a);
    let link = $a.attr("href") || baseUrl;

    const titleRaw = pickBestText(
      $a.html(),
      $a.text(),
      $a.closest("article,.event,.listing,.card,.post,.entry,.event-card,.event-item").find("h1,h2,h3,.title").first().html(),
      $a.closest("article,.event,.listing,.card,.post,.entry,.event-card,.event-item").find("h1,h2,h3,.title").first().text()
    );
    const title = stripHtml(titleRaw);

    // Find a nearby image for the anchor
    const imgEl =
      $a.find("img").first().get(0) ||
      $a.closest("article,.event,.listing,.card,.post,.entry,.event-card,.event-item").find("img").first().get(0);

    const $img = $(imgEl || []);
    const imgSrcRaw = $img.attr("src") || $img.attr("data-src") || $img.attr("data-lazy-src") || ogImg || "";
    const width = parseInt($img.attr("width") || "0", 10);

    if (!title || !imgSrcRaw) return;
    if (isJunkyTitle(title)) return;

    const imgAbs = absolutize(imgSrcRaw, baseUrl);
    if (isLikelyLogoUrl(imgAbs)) return; // skip logos/favicons

    cards.push({ title, link, img: imgAbs, width });
  });

  // Absolutize link + de-dupe (title+img)
  const seen = new Set();
  return cards.map(c => {
    return { ...c, link: absolutize(c.link, baseUrl) };
  }).filter(c => {
    const k = sha1(`${c.title}@@${c.img}`);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

// ---------- Image mirroring (Firebase token-based URL; no signBlob needed) ----------
function makeFirebaseDownloadUrl(bucket, path, token) {
  // path must be URL-encoded for the v0 API
  const encBucket = encodeURIComponent(bucket);
  const encPath = encodeURIComponent(path);
  return `https://firebasestorage.googleapis.com/v0/b/${encBucket}/o/${encPath}?alt=media&token=${token}`;
}

async function mirrorImageToStorage(cityKey, srcUrl, referer) {
  const safeUrl = (srcUrl || "").split("?")[0];
  const ext = (safeUrl.match(/\.(jpg|jpeg|png|webp|gif)$/i) || [,"jpg"])[1].toLowerCase();
  const dest = `gossip/ai/${cityKey}/${crypto.randomUUID()}.${ext}`;

  const res = await fetchWithTimeout(srcUrl, {
    timeoutMs: 20000,
    headers: {
      "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
      ...(referer ? { "Referer": referer } : {})
    }
  });
  if (!res.ok) throw new Error(`image fetch failed: ${res.status}`);

  // node-fetch v2 has res.buffer(); v3 has res.arrayBuffer()
  let buf;
  if (typeof res.buffer === "function") {
    buf = await res.buffer();
  } else if (typeof res.arrayBuffer === "function") {
    const ab = await res.arrayBuffer();
    buf = Buffer.from(ab);
  } else {
    throw new Error("no buffer reader available");
  }

  if (buf.length < 12 * 1024) throw new Error("image too small");

  const token = crypto.randomUUID();
  await storage.file(dest).save(buf, {
    contentType: `image/${ext === "jpg" ? "jpeg" : ext}`,
    resumable: false,
    metadata: {
      metadata: { firebaseStorageDownloadTokens: token } // <-- download token added
    }
  });

  const url = makeFirebaseDownloadUrl(BUCKET_NAME, dest, token);
  return { path: dest, url };
}

// ---------- Write post ----------
async function writeGossipPost({ cityKey, cityLabel, title, image, link, tags }) {
  const id = rtdb.ref().push().key;
  const now = Date.now();

  const post = {
    id,
    type: "ai-post",
    author: `BlackAppCrew${cityKey}`,
    authorAvatarUrl: LOGO_URL,
    text: title,
    imagePath: image.path || null,
    imageUrl: image.url || null,  // token-based URL
    eventUrl: link,
    city: cityLabel,
    tags: [ `#${cityLabel.split(",")[0]}` ],          // e.g., "#Charlotte"
    hashTags: Array.isArray(tags) ? tags.filter(t => t.startsWith("#")) : [],
    timestamp: now,
    source: "ai-scraper",
    region: cityKey
  };

  await rtdb.ref(`/gossip/posts/${id}`).set(post);
  return id;
}

async function isSeenAndMark(hash) {
  const ref = rtdb.ref(`/gossip/aiCrew/seen/${hash}`);
  const snap = await ref.get();
  if (snap.exists()) return true;
  await ref.set({ ts: Date.now() });
  return false;
}

// ---------- City worker (supports DEBUG) ----------
async function runCity(cityKey, cfg, DEBUG = false) {
  const tags = Array.isArray(cfg.tags) ? cfg.tags : [];
  const cityLabel = cfg.label || cityKey;
  const sources = Array.isArray(cfg.sources) ? cfg.sources.slice(0, 10) : [];

  let posted = 0;
  const debugNotes = [];

  for (const src of sources) {
    if (posted >= MAX_POSTS_PER_CITY_PER_RUN) break;

    try {
      const res = await fetchWithTimeout(src, { timeoutMs: 20000, headers: { "User-Agent": "Mozilla/5.0" }});
      if (!res.ok) {
        if (DEBUG) debugNotes.push({ src, reason: `fetch ${res.status}` });
        continue;
      }
      const html = await res.text();
      const cards = extractCards(html, src);
      if (DEBUG) debugNotes.push({ src, found: cards.length });

      for (const c of cards) {
        if (posted >= MAX_POSTS_PER_CITY_PER_RUN) break;

        const title = c.title || "";
        const link = c.link || src;
        const imgUrl = c.img || "";

        if (!isAcceptableCard({ title, link, imgUrl })) {
          if (DEBUG) debugNotes.push({ src, title, reason: "filtered:not-nightlifey-and/or-weak-image" });
          continue;
        }

        const h = sha1(`${cityKey}::${title}::${link}::${imgUrl}`);
        if (await isSeenAndMark(h)) {
          if (DEBUG) debugNotes.push({ src, title, reason: "dup" });
          continue;
        }

        if (c.width && c.width < MIN_IMAGE_WIDTH) {
          if (DEBUG) debugNotes.push({ src, title, reason: `too-small:${c.width}` });
          continue;
        }

        let image = { path: null, url: null };
        try {
          image = await mirrorImageToStorage(cityKey, imgUrl, src);
        } catch (e) {
          if (DEBUG) debugNotes.push({ src, title, reason: `mirror-failed:${e.message}` });
          image = { path: null, url: imgUrl }; // fallback if your UI can render direct URLs
        }

        await writeGossipPost({ cityKey, cityLabel, title, image, link, tags });
        posted++;
      }
    } catch (e) {
      if (DEBUG) debugNotes.push({ src, reason: `error:${e.message}` });
      console.warn(`[${cityKey}] source error ${src}:`, e.message);
    }
  }

  return DEBUG ? { posted, debugNotes } : posted;
}

// ---------- Run all cities ----------
async function runAllCities(targetCityKey /* optional */, DEBUG = false) {
  const snap = await rtdb.ref("/gossip/aiCrew/cities").get();
  if (!snap.exists()) {
    console.warn("No /gossip/aiCrew/cities config found.");
    return { posted: 0, byCity: {} };
  }
  const cfg = snap.val();
  const keys = Object.keys(cfg).filter(k => !targetCityKey || k === targetCityKey);

  const byCity = {};
  let total = 0;

  for (const k of keys) {
    const out = await runCity(k, cfg[k] || {}, DEBUG);
    byCity[k] = out;
    total += (DEBUG ? out.posted : out);
  }
  return { posted: total, byCity };
}

// ---------- Scheduler ----------
exports.aiBlackAppCrew = functions
  .runWith({ timeoutSeconds: 300, memory: "1GB" })
  .pubsub.schedule("every 60 minutes")
  .timeZone("America/New_York")
  .onRun(async () => {
    const result = await runAllCities(undefined, false);
    console.log("aiBlackAppCrew run result:", result);
    return null;
  });

// ---------- HTTP trigger (debug + bucket diag using token URL) ----------
exports.aiBlackAppCrewHTTP = functions
  .runWith({ timeoutSeconds: 300, memory: "1GB" })
  .https.onRequest(async (req, res) => {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
    if (req.method === "OPTIONS") return res.status(204).end();

    try {
      // DIAGNOSTIC: ?diag=bucket → write tiny file & return token-based URL
      if (String(req.query.diag || "") === "bucket") {
        try {
          const [meta] = await storage.getMetadata();
          const testPath = `gossip/ai/_diag_${Date.now()}.txt`;
          const token = crypto.randomUUID();
          await storage.file(testPath).save(Buffer.from("ok"), {
            contentType: "text/plain",
            resumable: false,
            metadata: { metadata: { firebaseStorageDownloadTokens: token } }
          });
          const url = makeFirebaseDownloadUrl(BUCKET_NAME, testPath, token);
          return res.json({
            ok: true,
            bucketSeenByFunction: storage.name,
            bucketMeta: { location: meta.location, storageClass: meta.storageClass },
            wroteTestFile: testPath,
            testFileDownloadUrl: url
          });
        } catch (e) {
          return res.status(500).json({
            ok: false,
            bucketSeenByFunction: storage && storage.name,
            error: `Bucket diag failed: ${e.message}`
          });
        }
      }

      const cityKey = String(req.query.city || "").trim() || null;
      const DEBUG = String(req.query.debug || "0") === "1";
      const result = await runAllCities(cityKey || undefined, DEBUG);
      res.json({ ok: true, result, debug: DEBUG });
    } catch (e) {
      console.error("aiBlackAppCrewHTTP error:", e);
      res.status(500).json({ ok: false, error: e.message });
    }
  });

// ---------- SAFE helpers for thumbs (fallbacks if not defined globally) ----------
function _safeGetLogoFallback() {
  try { return typeof getLogoFallback === "function" ? getLogoFallback() : "https://blackapp.io/images/blackapp-logo.png"; }
  catch { return "https://blackapp.io/images/blackapp-logo.png"; }
}
function _safeCfUrl(url, w) {
  try {
    if (typeof cfUrl === "function") {
      return cfUrl("imgThumb", { url, w, fallback: _safeGetLogoFallback(), fallbackScale: 0.25 });
    }
  } catch {}
  // Fallback: return source url (client can still render the full image)
  return url || _safeGetLogoFallback();
}

// ---------- AI Crew → bundle item adapter (with safe helpers) ----------
async function fetchAICrewPostsForBundle({ limit = 50, city /* e.g. 'Charlotte' or '#Charlotte' */, thumbWidth = 900 }) {
  const snap = await rtdb.ref("/gossip/posts").orderByChild("timestamp").limitToLast(500).get();
  if (!snap.exists()) return [];

  const wantTag = city ? ("#" + String(city).replace(/^#/, "")) : null;

  const rows = Object.values(snap.val() || {}).filter(p => p && p.source === "ai-scraper");

  const filtered = rows.filter(p => {
    if (!wantTag) return true;
    const tags = (Array.isArray(p.tags) ? p.tags : []).concat(Array.isArray(p.hashTags) ? p.hashTags : []);
    const norm = tags.map(t => String(t || "").toLowerCase());
    return norm.includes(wantTag.toLowerCase());
  });

  return filtered
    .sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0))
    .slice(0, limit)
    .map(p => {
      const title = String(p.text || p.title || "Nightlife").slice(0, 160);
      const link  = p.eventUrl || "";
      const image = p.imageUrl || null;
      const pub   = p.timestamp ? new Date(p.timestamp).toISOString() : new Date().toISOString();
      const thumb = _safeCfUrl(image || "", thumbWidth);

      return {
        id: p.id || (crypto && crypto.createHash ? crypto.createHash("sha1").update(`${title}@@${link}@@${image||""}`).digest("hex") : `${Date.now()}_${Math.random()}`),
        title,
        link,
        image,
        thumb,
        pubDate: Date.parse(pub),
        source: "ai-scraper",
        author: p.author || `BlackAppCrew${p.region || ""}`,
        avatar: p.authorAvatarUrl || "https://blackapp.io/images/blackapp-logo.png",
        tags: (Array.isArray(p.hashTags) && p.hashTags.length ? p.hashTags : (Array.isArray(p.tags) ? p.tags : [])),
        city: p.city || null,
        region: p.region || null
      };
    });
}



// === Admin upsert for /gossip/partners (key-guarded) ===
// POST /upsertPartner?key=ADMIN_INIT_KEY
// Body: { id, title, enabled=true, pageId?, igUserId?, lastSyncTs? }
exports.upsertPartner = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    if (req.method !== "POST") {
      return res.status(405).json({ ok: false, error: "Use POST" });
    }
    const adminKey = process.env.ADMIN_INIT_KEY || (functions.config().admin && functions.config().admin.init_key);
    const key = String(req.query.key || "");
    if (!adminKey || key !== adminKey) {
      return res.status(401).json({ ok: false, error: "unauthorized" });
    }

    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    const id = String(body.id || "").trim();
    if (!id) return res.status(400).json({ ok: false, error: "Missing field: id" });

    const payload = {
      enabled: body.enabled !== false,
      title: String(body.title || "").trim() || `${id} — Instagram`,
      pageId: body.pageId ? String(body.pageId) : undefined,
      igUserId: body.igUserId ? String(body.igUserId) : undefined,
      lastSyncTs: Number.isFinite(Number(body.lastSyncTs)) ? Number(body.lastSyncTs) : 0,
    };

    // Clean undefined so we don't write nulls unless provided
    Object.keys(payload).forEach((k) => payload[k] === undefined && delete payload[k]);

    await rtdb.ref(`/gossip/partners/${id}`).update(payload);
    return res.json({ ok: true, id, write: payload });
  } catch (e) {
    console.error("[upsertPartner] error:", e);
    return res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});


// Unwrap repeatedly if thumb is an imgThumb URL that points to another imgThumb... up to 10 layers.
function unwrapImgThumb(u) {
  let curr = String(u || "");
  let safety = 0;
  while (safety < 10) {
    let urlObj;
    try { urlObj = new URL(curr); } catch { break; }
    const isImgThumb = /\/imgThumb$/.test(urlObj.pathname) && urlObj.hostname.includes("cloudfunctions.net");
    if (!isImgThumb) break;

    const inner = urlObj.searchParams.get("url");
    if (!inner) break;

    // decode once; next loop will parse again if needed
    curr = decodeURIComponent(inner);
    safety++;
  }
  // force https if any upstream was http
  try { const uo = new URL(curr); if (uo.protocol === "http:") { uo.protocol = "https:"; return uo.toString(); } } catch {}
  return curr;
}




// ADMIN: Fix historic IG thumbs/images in RTDB (unwrap, https, rebuild single thumb)
// GET /fixOldIgThumbs?key=ADMIN_INIT_KEY&dry=1
// Fix older IG items that have nested/blank thumbs by rewriting to a clean imgThumb with 25% logo fallback.
// GET /fixOldIgThumbs?key=ADMIN_INIT_KEY&dry=1   (dry run)
// GET /fixOldIgThumbs?key=ADMIN_INIT_KEY&dry=0   (writes)
exports.fixOldIgThumbs = fn.https.onRequest(async (req, res) => {
  // CORS
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    return res.status(204).end();
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const key = String(req.query.key || "");
    const adminKey = process.env.ADMIN_INIT_KEY || (functions.config().admin && functions.config().admin.init_key);
    if (!key || key !== adminKey) return res.status(401).json({ error: "unauthorized" });

    const dry = String(req.query.dry || "1") !== "0";
    const limitPerPartner = Math.max(parseInt(req.query.limit || "0", 10) || 0, 0); // 0 = scan all

    const partnersSnap = await rtdb.ref("gossip/partners").get();
    const partners = partnersSnap.exists() ? partnersSnap.val() : {};
    const partnerIds = Object.keys(partners);

    let scanned = 0, rewrote = 0;
    const updates = {};

    for (const partnerId of partnerIds) {
      // Pull all items (or capped) newest-first by timestamp
      let q = rtdb.ref(`gossip/items/${partnerId}`).orderByChild("timestamp");
      const snap = await q.get();
      if (!snap.exists()) continue;

      const rows = [];
      snap.forEach(cs => rows.push(cs));
      rows.sort((a, b) => (b.val()?.timestamp || 0) - (a.val()?.timestamp || 0));
      const slice = limitPerPartner > 0 ? rows.slice(0, limitPerPartner) : rows;

      for (const cs of slice) {
        scanned++;
        const v = cs.val() || {};
        const keyPath = `gossip/items/${partnerId}/${cs.key}`;
        const currentThumb = v.thumb || "";
        const currentImage = v.image || v.rawThumbUrl || v.rawMediaUrl || "";

        // Figure out the best upstream image we can point at (unwrapping nested imgThumb → original)
        const baseUrl = unwrapImgThumb(currentThumb || currentImage || "");
        const hasBase = !!baseUrl;

        // Compute what the new thumb should be (always 25% logo fallback)
        const newThumb = cfUrl("imgThumb", {
          url: hasBase ? baseUrl : "",
          w: 900,
          fallback: getLogoFallback(),
          fallbackScale: 0.25,
        });

        // Rewrite if:
        //  - thumb is empty, OR
        //  - thumb is clearly an imgThumb-within-imgThumb chain, OR
        //  - thumb URL differs from the desired rebuilt one
        const needsRewrite =
          !currentThumb ||
          /\/imgThumb$/.test(currentThumb) && currentThumb.includes("url=") && decodeURIComponent(currentThumb).includes("/imgThumb?url=") ||
          currentThumb !== newThumb;

        if (needsRewrite) {
          rewrote++;
          if (!dry) {
            updates[`${keyPath}/thumb`] = newThumb;
            // also fix image if it was empty and we found a base
            if (!v.image && hasBase) updates[`${keyPath}/image`] = baseUrl;
          }
        }
      }
    }

    if (!dry && Object.keys(updates).length) {
      await rtdb.ref().update(updates);
    }

    return res.json({ ok: true, dry, partners: partnerIds.length, scanned, rewrote, wrote: dry ? 0 : Object.keys(updates).length });
  } catch (e) {
    console.error("fixOldIgThumbs error", e);
    return res.status(500).json({ error: String(e?.message || e) });
  }
});
