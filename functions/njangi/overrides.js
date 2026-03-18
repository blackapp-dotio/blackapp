// functions/njangi/overrides.js
/* eslint-disable no-console */

const functions = require("firebase-functions/v1");

/**
 * Factory that returns callable functions. This avoids re-initializing admin in this file.
 * Usage in index.js:
 *   const makeNjangiOverrides = require("./njangi/overrides");
 *   Object.assign(exports, makeNjangiOverrides({ fn, admin, firestore, rtdb }));
 */
module.exports = function makeNjangiOverrides({ fn, admin, firestore, rtdb }) {
  if (!fn || !admin || !firestore || !rtdb) {
    throw new Error("[njangi/overrides] Missing deps: fn/admin/firestore/rtdb");
  }

  const HttpsError = functions.https.HttpsError;

  // ---------------- Helpers ----------------
  function requireAuth(context) {
    if (!context.auth || !context.auth.uid) throw new HttpsError("unauthenticated", "Sign-in required.");
    return context.auth.uid;
  }

  function njGroupRef(groupId) {
    return firestore.collection("njangiGroups").doc(String(groupId));
  }
  function njMemberRef(groupId, uid) {
    return njGroupRef(groupId).collection("members").doc(String(uid));
  }
  function payoutRef(groupId, payoutIntentId) {
    return njGroupRef(groupId).collection("payoutIntents").doc(String(payoutIntentId));
  }
  function disputeRef(groupId, disputeId) {
    return njGroupRef(groupId).collection("disputes").doc(String(disputeId));
  }
  function ledgerCol(groupId) {
    return njGroupRef(groupId).collection("ledger");
  }

  async function getGroupAndRole(groupId, uid) {
    const gSnap = await njGroupRef(groupId).get();
    if (!gSnap.exists) throw new HttpsError("not-found", "Njangi group not found.");
    const g = gSnap.data() || {};

    // Owner shortcut
    if (g.ownerId && g.ownerId === uid) return { group: g, role: "owner" };

    const mSnap = await njMemberRef(groupId, uid).get();
    if (!mSnap.exists) return { group: g, role: null };
    const m = mSnap.data() || {};
    return { group: g, role: m.role || "member" };
  }

  function isAdminRole(role) {
    return role === "owner" || role === "admin";
  }

  function nowTs() {
    return admin.firestore.FieldValue.serverTimestamp();
  }

  async function writeLedger(groupId, uid, payload) {
    const base = {
      groupId: String(groupId),
      createdAt: nowTs(),
      createdBy: uid,
    };
    const ref = await ledgerCol(groupId).add({ ...base, ...payload });
    await ledgerCol(groupId).doc(ref.id).set({ id: ref.id }, { merge: true });
    return ref.id;
  }

  async function hasOpenDispute(groupId, { payoutIntentId, roundId }) {
    const disputes = njGroupRef(groupId).collection("disputes");

    // Query by payoutIntentId if provided; also check roundId if provided.
    const checks = [];

    if (payoutIntentId) {
      checks.push(
        disputes
          .where("status", "==", "open")
          .where("payoutIntentId", "==", String(payoutIntentId))
          .limit(1)
          .get()
      );
    }
    if (roundId) {
      checks.push(
        disputes
          .where("status", "==", "open")
          .where("roundId", "==", String(roundId))
          .limit(1)
          .get()
      );
    }

    if (!checks.length) return false;

    const results = await Promise.all(checks);
    return results.some((snap) => !snap.empty);
  }

  async function getStripeAccountId(uid) {
    try {
      const snap = await rtdb.ref(`users/${uid}/stripeAccountId`).get();
      const v = snap.exists() ? String(snap.val() || "").trim() : "";
      return v && v.startsWith("acct_") ? v : "";
    } catch (e) {
      console.warn("[njangi/overrides] stripeAccountId read failed", e);
      return "";
    }
  }

  function mustString(x, name) {
    const s = typeof x === "string" ? x.trim() : "";
    if (!s) throw new HttpsError("invalid-argument", `Missing ${name}.`);
    return s;
  }

  // ---------------- Callable: payout overrides ----------------
  // action: "pause" | "resume" | "earlyApprove" | "swapPayee"
  // data:
  //  groupId, payoutIntentId, action
  //  pause: { reason }
  //  swapPayee: { newPayeeUid, note }
  const njangiPayoutOverride = fn.https.onCall(async (data, context) => {
    const uid = requireAuth(context);

    const groupId = mustString(data?.groupId, "groupId");
    const payoutIntentId = mustString(data?.payoutIntentId, "payoutIntentId");
    const action = mustString(data?.action, "action");

    const { group, role } = await getGroupAndRole(groupId, uid);
    if (!isAdminRole(role)) throw new HttpsError("permission-denied", "Admin/Owner only.");

    // Load payout
    const pSnap = await payoutRef(groupId, payoutIntentId).get();
    if (!pSnap.exists) throw new HttpsError("not-found", "Payout intent not found.");
    const payout = { id: pSnap.id, ...(pSnap.data() || {}) };

    const roundId = payout.roundId || payoutIntentId;

    // Enforce dispute gate for resume/approve/swap
    if (action === "resume" || action === "earlyApprove" || action === "swapPayee") {
      const blocked = await hasOpenDispute(groupId, { payoutIntentId, roundId });
      if (blocked) throw new HttpsError("failed-precondition", "Cannot proceed while a dispute is open.");
    }

    const ts = nowTs();

    if (action === "pause") {
      const reason = mustString(data?.reason, "reason");
      await payoutRef(groupId, payoutIntentId).set(
        {
          status: "paused",
          pausedBy: uid,
          pausedAt: ts,
          pausedReason: reason.slice(0, 300),
          updatedAt: ts,
        },
        { merge: true }
      );

      await writeLedger(groupId, uid, {
        type: "PAYOUT_PAUSED",
        payoutIntentId,
        roundId: String(roundId),
        reason: reason.slice(0, 800),
      });

      return { ok: true };
    }

    if (action === "resume") {
      await payoutRef(groupId, payoutIntentId).set(
        {
          status: "ready",
          resumedBy: uid,
          resumedAt: ts,
          updatedAt: ts,
        },
        { merge: true }
      );

      await writeLedger(groupId, uid, {
        type: "PAYOUT_RESUMED",
        payoutIntentId,
        roundId: String(roundId),
      });

      return { ok: true };
    }

    if (action === "earlyApprove") {
      await payoutRef(groupId, payoutIntentId).set(
        {
          status: "approved",
          approvedBy: uid,
          approvedAt: ts,
          approvedMode: "manual_early",
          updatedAt: ts,
        },
        { merge: true }
      );

      await writeLedger(groupId, uid, {
        type: "PAYOUT_APPROVED_MANUAL",
        payoutIntentId,
        roundId: String(roundId),
        mode: "manual_early",
      });

      return { ok: true };
    }

    if (action === "swapPayee") {
      const newPayeeUid = mustString(data?.newPayeeUid, "newPayeeUid");
      const note = mustString(data?.note, "note");

      // Require new payee to have Stripe connected
      const acct = await getStripeAccountId(newPayeeUid);
      if (!acct) throw new HttpsError("failed-precondition", "New payee has not connected Stripe.");

      await payoutRef(groupId, payoutIntentId).set(
        {
          payeeUid: newPayeeUid,
          payeeStripeAccountId: acct,
          payeeChangedBy: uid,
          payeeChangedAt: ts,
          payeeChangeNote: note.slice(0, 800),
          updatedAt: ts,
        },
        { merge: true }
      );

      await writeLedger(groupId, uid, {
        type: "PAYEE_SWAPPED",
        payoutIntentId,
        roundId: String(roundId),
        newPayeeUid,
        note: note.slice(0, 800),
      });

      return { ok: true };
    }

    throw new HttpsError("invalid-argument", `Unsupported action: ${action}`);
  });

  // ---------------- Callable: dispute close (Phase 2.1) ----------------
  // data: { groupId, disputeId, action, note? }
  // action: "resolve_resume" | "resolve_keep_paused" | "dismiss"
  const njangiCloseDispute = fn.https.onCall(async (data, context) => {
    const uid = requireAuth(context);

    const groupId = mustString(data?.groupId, "groupId");
    const disputeId = mustString(data?.disputeId, "disputeId");
    const action = mustString(data?.action, "action");
    const note = typeof data?.note === "string" ? data.note.trim() : "";

    const { role } = await getGroupAndRole(groupId, uid);
    if (!isAdminRole(role)) throw new HttpsError("permission-denied", "Admin/Owner only.");

    const dSnap = await disputeRef(groupId, disputeId).get();
    if (!dSnap.exists) throw new HttpsError("not-found", "Dispute not found.");
    const dispute = { id: dSnap.id, ...(dSnap.data() || {}) };

    if (dispute.status !== "open") throw new HttpsError("failed-precondition", "Dispute is not open.");

    const payoutIntentId = String(dispute.payoutIntentId || "").trim();
    const roundId = String(dispute.roundId || payoutIntentId || "").trim();

    const ts = nowTs();

    // Close dispute doc
    await disputeRef(groupId, disputeId).set(
      {
        status: "closed",
        closedBy: uid,
        closedAt: ts,
        resolutionAction: action,
        resolutionNote: note.slice(0, 800),
      },
      { merge: true }
    );

    // If asked to resume payout, do so (but only if payoutIntentId is present)
    if (action === "resolve_resume" && payoutIntentId) {
      await payoutRef(groupId, payoutIntentId).set(
        {
          status: "ready",
          resumedBy: uid,
          resumedAt: ts,
          updatedAt: ts,
        },
        { merge: true }
      );
    }

    await writeLedger(groupId, uid, {
      type: "DISPUTE_CLOSED",
      disputeId,
      payoutIntentId: payoutIntentId || null,
      roundId: roundId || null,
      action,
      note: note.slice(0, 800),
    });

    return { ok: true };
  });

  return {
    njangiPayoutOverride,
    njangiCloseDispute,
  };
};

