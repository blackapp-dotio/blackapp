/* eslint-disable no-console */
// functions/njangi/connect.js

const admin = require("firebase-admin");
const corsMw = require("cors")({ origin: true });
const functions = require("firebase-functions/v1");

function getBearer(req) {
  const h = req.headers.authorization || "";
  const m = h.match(/^Bearer (.+)$/i);
  return m ? m[1] : "";
}

async function requireUser(req) {
  const token = getBearer(req);
  if (!token) throw new Error("Missing Authorization Bearer token.");
  return await admin.auth().verifyIdToken(token); // { uid, ... }
}

function must(v, msg) {
  if (v === undefined || v === null || v === "") throw new Error(msg);
  return v;
}

function safeNum(v) {
  const n = Number(v);
  if (!isFinite(n)) return null;
  return n;
}

function moneyToCents(amount) {
  const n = safeNum(amount);
  if (n === null || n <= 0) throw new Error("Invalid amount.");
  return Math.round(n * 100);
}

function nowTs() {
  return admin.firestore.FieldValue.serverTimestamp();
}

// Configure via functions config where possible.
// Required:
// - stripe.secret_key already in your index.js requireStripe()
// Optional:
// - stripe.connect_return = "https://blackapp.io/njangi"
// - stripe.connect_refresh = "https://blackapp.io/njangi?connect=refresh"
function getConnectUrls() {
  const cfg = (() => { try { return functions.config(); } catch { return {}; } })();
  const ret =
    (cfg.stripe && cfg.stripe.connect_return) ||
    process.env.STRIPE_CONNECT_RETURN ||
    "https://blackapp.io/njangi?connect=return";
  const refresh =
    (cfg.stripe && cfg.stripe.connect_refresh) ||
    process.env.STRIPE_CONNECT_REFRESH ||
    "https://blackapp.io/njangi?connect=refresh";
  return { returnUrl: ret, refreshUrl: refresh };
}

module.exports = function buildNjangiConnectExports(opts) {
  const {
    fn,            // functions.region(...)
    firestore,     // admin.firestore()
    requireStripe, // your requireStripe() from index.js
    PLATFORM_FEE_RATE, // 0.05
  } = opts;

  // -------------------------------
  // 1) Create Stripe Connect link
  // -------------------------------
  const njangiCreateConnectLink = fn.https.onRequest((req, res) => {
    corsMw(req, res, async () => {
      try {
        if (req.method !== "POST") return res.status(405).json({ ok: false, error: "Use POST." });

        const decoded = await requireUser(req);
        const uid = decoded.uid;

        const stripe = requireStripe();
        const { returnUrl, refreshUrl } = getConnectUrls();

        const uRef = firestore.collection("users").doc(uid);
        const uSnap = await uRef.get();
        const uData = uSnap.exists ? (uSnap.data() || {}) : {};

        let accountId = uData?.stripeConnect?.accountId || "";

        // Default to Express
        if (!accountId) {
          const acct = await stripe.accounts.create({
            type: "express",
            capabilities: {
              transfers: { requested: true },
            },
            metadata: { app: "njangi", uid },
          });
          accountId = acct.id;

          await uRef.set(
            {
              stripeConnect: {
                accountId,
                type: "express",
                createdAt: nowTs(),
                lastUpdated: nowTs(),
              },
            },
            { merge: true }
          );
        }

        const link = await stripe.accountLinks.create({
          account: accountId,
          refresh_url: refreshUrl,
          return_url: returnUrl,
          type: "account_onboarding",
        });

        return res.json({ ok: true, url: link.url, accountId });
      } catch (e) {
        console.error("[njangiCreateConnectLink] error:", e);
        return res.status(400).json({ ok: false, error: e.message || "Failed." });
      }
    });
  });

  // -----------------------------------
  // 2) Stripe Login link (manage account)
  // -----------------------------------
  const njangiCreateConnectLoginLink = fn.https.onRequest((req, res) => {
    corsMw(req, res, async () => {
      try {
        if (req.method !== "POST") return res.status(405).json({ ok: false, error: "Use POST." });

        const decoded = await requireUser(req);
        const uid = decoded.uid;

        const stripe = requireStripe();

        const uRef = firestore.collection("users").doc(uid);
        const uSnap = await uRef.get();
        const uData = uSnap.exists ? (uSnap.data() || {}) : {};

        const accountId = uData?.stripeConnect?.accountId || "";
        if (!accountId) throw new Error("No connected Stripe account found. Please connect first.");

        const login = await stripe.accounts.createLoginLink(accountId);
        return res.json({ ok: true, url: login.url, accountId });
      } catch (e) {
        console.error("[njangiCreateConnectLoginLink] error:", e);
        return res.status(400).json({ ok: false, error: e.message || "Failed." });
      }
    });
  });

  // --------------------------------------------------------
  // 3) Create a withdrawal REQUEST (no transfer in Phase 4.4)
  // --------------------------------------------------------
  // This writes njangiWithdrawals/* in a locked-down, fee-safe way.
  // Phase 5 will process "approved" withdrawals into Stripe transfers.
  const njangiCreateWithdrawalRequest = fn.https.onRequest((req, res) => {
    corsMw(req, res, async () => {
      try {
        if (req.method !== "POST") return res.status(405).json({ ok: false, error: "Use POST." });

        const decoded = await requireUser(req);
        const uid = decoded.uid;

        const body = req.body || {};
        const amount = safeNum(body.amount);
        const currency = String(body.currency || "USD").toUpperCase();

        must(amount, "Missing amount.");

        // Fee must remain 5% and is not editable client-side
        const feeRate = Number(PLATFORM_FEE_RATE || 0.05);
        const feePct = Math.round(feeRate * 100);

        if (feePct !== 5) {
          // Safety: if someone changes env accidentally, still enforce 5
          throw new Error("Platform fee config mismatch. Expected 5%.");
        }

        // Check wallet available
        const wRef = firestore.collection("wallets").doc(uid);
        const wSnap = await wRef.get();
        const w = wSnap.exists ? (wSnap.data() || {}) : {};
        const available = Number(w.available || 0);

        if (amount <= 0) throw new Error("Amount must be > 0.");
        if (amount > available) throw new Error("Insufficient wallet balance.");

        // Must be connected (for later payout processing)
        const uRef = firestore.collection("users").doc(uid);
        const uSnap = await uRef.get();
        const uData = uSnap.exists ? (uSnap.data() || {}) : {};
        const accountId = uData?.stripeConnect?.accountId || "";
        if (!accountId) throw new Error("Connect your Stripe wallet before withdrawing.");

        const feeAmount = Number((amount * feeRate).toFixed(2));
        const netAmount = Number((amount - feeAmount).toFixed(2));

        const cents = moneyToCents(amount); // validation only
        void cents;

        // Create withdrawal request
        const wdRef = firestore.collection("njangiWithdrawals").doc();
        await wdRef.set({
          uid,
          amount,
          currency,
          status: "requested",
          platformFeePercent: 5,
          platformFeeAmount: feeAmount,
          netAmount,
          stripe: { destinationAccountId: accountId },
          createdAt: nowTs(),
          updatedAt: nowTs(),
          // Optional routing later:
          // groupId: null,
          // clubFundId: null,
        });

        return res.json({ ok: true, withdrawalId: wdRef.id });
      } catch (e) {
        console.error("[njangiCreateWithdrawalRequest] error:", e);
        return res.status(400).json({ ok: false, error: e.message || "Failed." });
      }
    });
  });

  return {
    njangiCreateConnectLink,
    njangiCreateConnectLoginLink,
    njangiCreateWithdrawalRequest,
  };
};

