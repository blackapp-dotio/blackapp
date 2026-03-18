/* eslint-disable no-console */
// functions/njangi/money.js
const admin = require("firebase-admin");
const functions = require("firebase-functions/v1");
const corsMw = require("cors")({ origin: true });
const Stripe = require("stripe");

function requireStripe(requireStripeFn) {
  const s = requireStripeFn();
  if (!s) throw new Error("Stripe not initialized");
  return s;
}

function getBearer(req) {
  const h = req.headers.authorization || "";
  const m = h.match(/^Bearer (.+)$/i);
  return m ? m[1] : "";
}

async function verifyFirebaseUser(req) {
  const token = getBearer(req);
  if (!token) throw new Error("Missing Authorization Bearer token.");
  const decoded = await admin.auth().verifyIdToken(token);
  return decoded; // { uid, ... }
}

function must(v, msg) {
  if (v === undefined || v === null || v === "") throw new Error(msg);
  return v;
}

function safeStr(v) {
  return typeof v === "string" ? v.trim() : "";
}

function moneyToCents(amount) {
  const n = Number(amount || 0);
  if (!isFinite(n) || n <= 0) throw new Error("Invalid amount.");
  return Math.round(n * 100);
}

function frontendBase() {
  // keep stable; you can switch later to env/config
  return "https://blackapp.io";
}

module.exports = function buildNjangiMoneyExports(opts) {
  const {
    fn, // functions.region(...)
    firestore, // admin.firestore()
    requireStripe: requireStripeFn, // your requireStripe() from index.js
    PLATFORM_FEE_RATE, // 0.05
  } = opts;

  // -------------------------------
  // 1) Create contribution checkout
  // -------------------------------
  const njangiCreateContributionCheckout = fn.https.onRequest((req, res) => {
    corsMw(req, res, async () => {
      try {
        if (req.method !== "POST") {
          res.status(405).json({ ok: false, error: "Use POST." });
          return;
        }

        const decoded = await verifyFirebaseUser(req);
        const uid = decoded.uid;

        const body = req.body || {};
        const groupId = safeStr(body.groupId);
        const roundId = safeStr(body.roundId);

        must(groupId, "Missing groupId.");
        must(roundId, "Missing roundId.");

        // Load group and membership
        const gRef = firestore.collection("njangiGroups").doc(groupId);
        const gSnap = await gRef.get();
        if (!gSnap.exists) throw new Error("Group not found.");

        const group = gSnap.data() || {};
        const mRef = gRef.collection("members").doc(uid);
        const mSnap = await mRef.get();
        if (!mSnap.exists) throw new Error("You are not a member of this group.");

        // Load round (optional but recommended)
        const rRef = gRef.collection("rounds").doc(roundId);
        const rSnap = await rRef.get();
        if (!rSnap.exists) throw new Error("Round not found.");

        const round = rSnap.data() || {};

        // Amount/currency from group definition (authoritative)
        const amount = Number(group.contributionAmount || 0);
        const currency = String((group.currency || "USD")).toLowerCase();

        const cents = moneyToCents(amount);

        const stripe = requireStripe(requireStripeFn);

        // Idempotency per user+round (prevents duplicate sessions spamming)
        const idemKey = `njg_contrib_${groupId}_${roundId}_${uid}`;

        const base = frontendBase();
        const successUrl = `${base}/njangi?paid=1&groupId=${encodeURIComponent(groupId)}&roundId=${encodeURIComponent(roundId)}&session_id={CHECKOUT_SESSION_ID}`;
        const cancelUrl = `${base}/njangi?canceled=1&groupId=${encodeURIComponent(groupId)}&roundId=${encodeURIComponent(roundId)}`;

        const session = await stripe.checkout.sessions.create(
          {
            mode: "payment",
            payment_method_types: ["card"],
            line_items: [
              {
                price_data: {
                  currency,
                  product_data: {
                    name: `Njangi Contribution — ${group.name || "Group"}`,
                    description: `Round ${round.index ?? ""}`.trim(),
                  },
                  unit_amount: cents,
                },
                quantity: 1,
              },
            ],
            success_url: successUrl,
            cancel_url: cancelUrl,
            metadata: {
              app: "njangi",
              kind: "contribution",
              groupId,
              roundId,
              uid,
              currency: currency.toUpperCase(),
              amount: String(amount),
              feeRate: String(PLATFORM_FEE_RATE || 0.05),
            },
          },
          { idempotencyKey: idemKey }
        );

        res.json({ ok: true, url: session.url });
      } catch (e) {
        console.error("[njangiCreateContributionCheckout] error:", e);
        res.status(400).json({ ok: false, error: e.message || "Failed." });
      }
    });
  });

  // --------------------------------
  // 2) Stripe webhook: record payment
  // --------------------------------
  // IMPORTANT: you must set a webhook secret for this endpoint:
  // firebase functions:config:set stripe.njangi_webhook_secret="whsec_..."
  const njangiStripeWebhook = fn.https.onRequest(async (req, res) => {
    try {
      const stripe = requireStripe(requireStripeFn);

      const whSecret =
        (functions.config().stripe && functions.config().stripe.njangi_webhook_secret) ||
        process.env.STRIPE_NJANGI_WEBHOOK_SECRET ||
        "";

      if (!whSecret) {
        res.status(500).send("Missing webhook secret.");
        return;
      }

      const sig = req.headers["stripe-signature"];
      if (!sig) {
        res.status(400).send("Missing Stripe signature.");
        return;
      }

      let event;
      try {
        event = stripe.webhooks.constructEvent(req.rawBody, sig, whSecret);
      } catch (err) {
        console.error("[njangiStripeWebhook] signature verify failed:", err);
        res.status(400).send("Webhook signature verification failed.");
        return;
      }

      // Idempotency: store Stripe event IDs
      const evtRef = firestore.collection("stripeEvents").doc(event.id);
      const evtSnap = await evtRef.get();
      if (evtSnap.exists) {
        res.json({ received: true, duplicate: true });
        return;
      }

      // Handle completion
      if (event.type === "checkout.session.completed") {
        const session = event.data.object || {};
        const md = session.metadata || {};

        if (md.app === "njangi" && md.kind === "contribution") {
          const groupId = safeStr(md.groupId);
          const roundId = safeStr(md.roundId);
          const uid = safeStr(md.uid);

          if (!groupId || !roundId || !uid) throw new Error("Missing metadata.");

          const gRef = firestore.collection("njangiGroups").doc(groupId);
          const rRef = gRef.collection("rounds").doc(roundId);

          // Write contribution + ledger atomically-ish
          await firestore.runTransaction(async (tx) => {
            const gSnap = await tx.get(gRef);
            const rSnap = await tx.get(rRef);

            if (!gSnap.exists) throw new Error("Group missing.");
            if (!rSnap.exists) throw new Error("Round missing.");

            const group = gSnap.data() || {};
            const round = rSnap.data() || {};

            const amount = Number(group.contributionAmount || md.amount || 0);
            const currency = String((group.currency || md.currency || "USD")).toUpperCase();

            // Contribution doc keyed by session id to prevent duplicates
            const cRef = gRef.collection("contributions").doc(String(session.id));
            const cSnap = await tx.get(cRef);
            if (!cSnap.exists) {
              tx.set(cRef, {
                uid,
                groupId,
                roundId,
                roundIndex: round.index ?? null,
                amount,
                currency,
                status: "paid",
                source: "stripe",
                stripe: {
                  sessionId: session.id,
                  paymentIntent: session.payment_intent || null,
                  amountTotal: session.amount_total || null,
                  currency: session.currency || null,
                },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              });
            }

            // Update round paidMembers (arrayUnion)
            tx.update(rRef, {
              paidMembers: admin.firestore.FieldValue.arrayUnion(uid),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            // Ledger immutable entry
            const lRef = gRef.collection("ledger").doc();
            tx.set(lRef, {
              type: "CONTRIBUTION",
              ts: admin.firestore.FieldValue.serverTimestamp(),
              amount,
              currency,
              fromUid: uid,
              toUid: null,
              note: `Contribution received (Round ${round.index ?? ""})`.trim(),
              stripeSessionId: session.id,
            });

            // Mark event processed
            tx.set(evtRef, {
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              type: event.type,
              app: "njangi",
            });
          });
        }
      }

      res.json({ received: true });
    } catch (e) {
      console.error("[njangiStripeWebhook] error:", e);
      res.status(400).send(e.message || "Webhook handler failed.");
    }
  });

  return {
    njangiCreateContributionCheckout,
    njangiStripeWebhook,
  };
};

