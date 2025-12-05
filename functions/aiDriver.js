// functions/aiDriver.js
// Unified OpenRouter driver with smart fallbacks, retries, and safe defaults.
// Aligns with the Life Sync AI flow (zora.chat, persona summaries).

const functions = require("firebase-functions/v1");

// Prefer global fetch (Node 18+). Lazy-import node-fetch if needed.
const fetch =
  typeof globalThis.fetch === "function"
    ? globalThis.fetch
    : (...args) => import("node-fetch").then(({ default: f }) => f(...args));

// ---------------------------
// Config helpers
// ---------------------------
function fc() {
  try { return functions.config(); } catch { return {}; }
}
function fromCfg(key) {
  const c = fc();
  return (c.openrouter && c.openrouter[key]) || "";
}

// Reads from OPENROUTER_* env first, then functions.config().openrouter.*, then default
function cfg(key, def = "") {
  const envMap = {
    api_key: "OPENROUTER_API_KEY",
    model: "OPENROUTER_MODEL",
    fast_model: "OPENROUTER_FAST_MODEL",
    temperature: "OPENROUTER_TEMPERATURE",
    site_url: "OPENROUTER_SITE_URL",
    app_name: "OPENROUTER_APP_NAME",
    timeout_ms: "OPENROUTER_TIMEOUT_MS",
  };
  const envName = envMap[key] || key.toUpperCase();
  return process.env[envName] || fromCfg(key) || def;
}

// ---------------------------
// Defaults & model strategy
// ---------------------------

const SYSTEM_BASE =
  "You are Zora, the lifestyle & nightlife AI for BlackApp. " +
  "Be concise, practical, and upbeat. Prefer short bullets and 2–4 actionable options. " +
  "When recommending venues or plans, keep it local, time-aware, and budget-aware if asked.";

// Good, generally available models on OpenRouter (no ':free' suffixes)
const GLOBAL_FALLBACKS = [
  "qwen/qwen-2.5-7b-instruct",
  "deepseek/deepseek-chat",
  "google/gemini-1.5-flash",
  "meta-llama/llama-3.1-8b-instruct",
  "openai/gpt-4o-mini"
];

// Strip accidental suffixes like ':free' which caused your 404 earlier.
function normalizeModel(name) {
  if (!name) return name;
  return String(name).replace(/:free\b/gi, "");
}

// Build a unique fallback list for a given strength.
function modelListFor(strength) {
  const preferred = normalizeModel(
    strength === "fast"
      ? (cfg("fast_model") || cfg("model"))
      : (cfg("model") || cfg("fast_model"))
  );

  const seen = new Set();
  const list = [preferred, ...GLOBAL_FALLBACKS]
    .filter(Boolean)
    .map(normalizeModel)
    .filter(m => !seen.has(m) && seen.add(m));

  return list.length ? list : GLOBAL_FALLBACKS;
}

// ---------------------------
// Core OpenRouter call (single attempt, with per-call timeout)
// ---------------------------
async function callOpenRouterOnce({ model, system, user, temperature, siteURL, appName, timeoutMs }) {
  const apiKey = cfg("api_key");
  if (!apiKey) throw new Error("Missing OpenRouter API key (set openrouter.api_key or OPENROUTER_API_KEY)");

  const headers = {
    "Authorization": `Bearer ${apiKey}`,
    "Content-Type": "application/json",
    // Recommended attribution headers
    "HTTP-Referer": siteURL || cfg("site_url", "https://blackapp.io"),
    "X-Title": appName || cfg("app_name", "BlackApp"),
  };

  const body = {
    model,
    temperature: typeof temperature === "number"
      ? temperature
      : Number(cfg("temperature", "0.6")),
    messages: [
      system ? { role: "system", content: system } : null,
      { role: "user", content: user || "" },
    ].filter(Boolean),
    stream: false,
  };

  const controller = new AbortController();
  const tHandle = setTimeout(() => controller.abort(), Number(timeoutMs || cfg("timeout_ms", "18000")));

  let resp, txt;
  try {
    resp = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    txt = await resp.text();
  } catch (e) {
    clearTimeout(tHandle);
    // Surface aborts as a clean message
    if (e.name === "AbortError") throw new Error(`OpenRouter timeout after ${timeoutMs || cfg("timeout_ms", "18000")}ms`);
    throw e;
  } finally {
    clearTimeout(tHandle);
  }

  if (!resp.ok) {
    throw new Error(`OpenRouter HTTP ${resp.status}: ${txt}`);
  }

  let data;
  try { data = JSON.parse(txt); } catch { data = {}; }

  const content =
    data?.choices?.[0]?.message?.content ||
    data?.choices?.map((c) => c.message?.content).filter(Boolean).join("\n") ||
    "";

  return { text: (content || "").trim(), model };
}

// ---------------------------
// Retry wrapper (handles 429/5xx and model fallback)
// ---------------------------
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function shouldRetry(errMsg) {
  const s = String(errMsg || "").toLowerCase();
  return s.includes("429") || s.includes("rate limit") || s.includes("5") || s.includes("timeout");
}

async function callOpenRouterChatWithFallback({ strength, system, user }) {
  const models = modelListFor(strength);
  let lastErr;

  // Up to 2 retries per model if rate/timeout/server error.
  const MAX_RETRIES = 2;

  for (const model of models) {
    let attempt = 0;
    while (attempt <= MAX_RETRIES) {
      try {
        return await callOpenRouterOnce({
          model,
          system,
          user,
          temperature: strength === "creative" ? 0.9 : 0.5,
          siteURL: cfg("site_url", "https://blackapp.io"),
          appName: cfg("app_name", "BlackApp"),
          timeoutMs: cfg("timeout_ms", "18000"),
        });
      } catch (e) {
        lastErr = e;
        const retryable = shouldRetry(e.message);
        if (!retryable || attempt === MAX_RETRIES) break;
        // Exponential backoff with jitter
        const backoff = Math.min(1000 * Math.pow(2, attempt), 4000) + Math.floor(Math.random() * 250);
        await sleep(backoff);
        attempt += 1;
      }
    }
    // Fall through to next model
  }
  throw lastErr || new Error("All OpenRouter models failed.");
}

// ---------------------------
// Card helper (unchanged behavior)
// ---------------------------
function toCardsFromText(text) {
  const lines = (text || "").split("\n").map((l) => l.trim()).filter(Boolean);
  const bullets = lines.filter((l) => /^[-•]\s+/.test(l));
  if (bullets.length) {
    return [
      { type: "title", text: "Here’s the move ✨" },
      { type: "bullets", items: bullets.map((b) => b.replace(/^[-•]\s*/, "")) },
    ];
  }
  return [
    { type: "title", text: "Here’s the move ✨" },
    { type: "subtitle", text: text || "No suggestions yet." },
  ];
}

// ---------------------------
// Public API
// ---------------------------
async function runAI({ system, user, strength = "fast" }) {
  const sys = system || SYSTEM_BASE;
  return callOpenRouterChatWithFallback({ strength, system: sys, user });
}

module.exports = { runAI, toCardsFromText, SYSTEM_BASE };
