// functions/njangi/premium.js
/* eslint-disable no-console */
const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

// IMPORTANT:
// - Do NOT call admin.initializeApp() here.
// - Your main functions/index.js already does it once.

const firestore = admin.firestore();

const NJANGI_REGION = "us-central1";
const PLATFORM_WITHDRAWAL_FEE_PERCENT = 5; // immutable, undisputable
const AUTO_APPROVE_TZ = "America/New_York";
const AUTO_APPROVE_HOUR_LOCAL = 9; // 9:00 AM ET

// ----------------------------
// Helpers
// ----------------------------
function safeNumber(n, fallback = 0) {
  const x = Number(n);
  return Number.isFinite(x) ? x : fallback;
}

function money2(n) {
  return +safeNumber(n, 0).toFixed(2);
}

function computeFee(gross) {
  const g = money2(gross);
  const fee = money2(g * (PLATFORM_WITHDRAWAL_FEE_PERCENT / 100));
  const net = money2(g - fee);
  return { gross: g, fee, net };
}

/**
 * Compute Firestore Timestamp for "next day at 9:00 AM America/New_York".
 * Uses Intl to anchor to ET calendar date and finds the UTC moment that formats to 09:00 in ET.
 * Deterministic and DST-safe enough for production scheduling.
 */
function nextDayAtNineAM_ET(now = new Date()) {
  const tz = AUTO_APPROVE_TZ;

  // Extract ET year/month/day for "today"
  const ymdFmt = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });

  const parts = ymdFmt.formatToParts(now).reduce((acc, p) => {
    if (p.type !== "literal") acc[p.type] = p.value;
    return acc;
  }, {});

  const y = Number(parts.year);
  const m = Number(parts.month);
  const d = Number(parts.day);

  // Move to "tomorrow" on the ET calendar by adding 1 day to the UTC date constructed from ET y/m/d
  const baseUTC = new Date(Date.UTC(y, m - 1, d, 0, 0, 0));
  const tomorrowUTC = new Date(baseUTC.getTime() + 24 * 60 * 60 * 1000);

  // Now find the UTC instant that is 09:00 ET for that ET date.
  const targetYMD = ymdFmt.formatToParts(tomorrowUTC).reduce((acc, p) => {
    if (p.type !== "literal") acc[p.type] = p.value;
    return acc;
  }, {});

  const ty = Number(targetYMD.year);
  const tm = Number(targetYMD.month);
  const td = Number(targetYMD.day);

  // Start search around 14:00Z and scan +/- 6 hours in 15-min steps to find 09:00 ET
  const start = Date.UTC(ty, tm - 1, td, 14, 0, 0);
  const etTimeFmt = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
  });

  let found = null;
  for (let deltaMin = -360; deltaMin <= 360; deltaMin += 15) {
    const cand = new Date(start + deltaMin * 60 * 1000);
    const t = etTimeFmt.format(cand); // "HH:MM"
    if (t === `${String(AUTO_APPROVE_HOUR_LOCAL).padStart(2, "0")}:00`) {
      found = cand;
      break;
    }
  }

  return admin.firestore.Timestamp.fromDate(found || new Date(start));
}

function groupRef(groupId) {
  return firestore.doc(`njangiGroups/${groupId}`);
}

function roundRef(groupId, roundId) {
  return firestore.doc(`njangiGroups/${groupId}/rounds/${roundId}`);
}

function payoutRef(groupId, roundId) {
  // Idempotency: payoutIntent docId = roundId
  return firestore.doc(`njangiGroups/${groupId}/payoutIntents/${roundId}`);
}

function ledgerCol(groupId) {
  return firestore.collection(`njangiGroups/${groupId}/ledger`);
}

function disputesCol(groupId) {
  return firestore.collection(`njangiGroups/${groupId}/disputes`);
}

// ----------------------------
// 1) Enforce platform fee immutability at group doc level
// ----------------------------
exports.enforceNjangiPlatformFee = functions
  .region(NJANGI_REGION)
  .firestore.document("njangiGroups/{groupId}")
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;

    const ref = change.after.ref;
    const data = change.after.data() || {};
    const current = data.platformWithdrawalFeePercent;

    if (current === PLATFORM_WITHDRAWAL_FEE_PERCENT) return;

    console.warn("[njangi] platform fee corrected", {
      groupId: context.params.groupId,
      from: current,
      to: PLATFORM_WITHDRAWAL_FEE_PERCENT,
    });

    await ref.set(
      { platformWithdrawalFeePercent: PLATFORM_WITHDRAWAL_FEE_PERCENT },
      { merge: true }
    );
  });

// ----------------------------
// 2) Auto-create payout intent when a confirmed contribution is written
// ----------------------------
exports.onNjangiContributionWritten = functions
  .region(NJANGI_REGION)
  .firestore.document("njangiGroups/{groupId}/contributions/{contributionId}")
  .onWrite(async (change, context) => {
    const groupId = context.params.groupId;

    if (!change.after.exists) return;

    const after = change.after.data() || {};
    const before = change.before.exists ? (change.before.data() || {}) : null;

    const roundId = String(after.roundId || "").trim();
    if (!roundId) return;

    const isConfirmed = String(after.status || "pending") === "confirmed";
    const wasConfirmed = before ? String(before.status || "pending") === "confirmed" : false;

    // Only count transitions into confirmed
    if (!isConfirmed || wasConfirmed) return;

    const amount = safeNumber(after.amount, 0);
    if (!Number.isFinite(amount) || amount <= 0) return;

    const rRef = roundRef(groupId, roundId);
    const pRef = payoutRef(groupId, roundId);
    const lRef = ledgerCol(groupId).doc();

    await firestore.runTransaction(async (tx) => {
      const rSnap = await tx.get(rRef);
      if (!rSnap.exists) {
        console.warn("[njangi] round not found for contribution", { groupId, roundId });
        return;
      }

      const r = rSnap.data() || {};
      const status = String(r.status || "open");

      const requiredTotal = money2(r.requiredTotal || 0);
      const received0 = money2(r.receivedTotal || 0);
      const received = money2(received0 + amount);

      tx.set(rRef, { receivedTotal: received }, { merge: true });

      // Only create payout intent once when crossing threshold and round is open
      if (requiredTotal > 0 && received >= requiredTotal && status === "open") {
        const payeeUid = String(r.payeeUid || "").trim();
        const roundNumber = safeNumber(r.roundNumber, 1);

        const { gross, fee, net } = computeFee(requiredTotal);
        const autoApproveAt = nextDayAtNineAM_ET(new Date());

        const pSnap = await tx.get(pRef);
        if (!pSnap.exists) {
          tx.set(pRef, {
            groupId,
            roundId,
            roundNumber,
            payeeUid,
            grossAmount: gross,
            feePercent: PLATFORM_WITHDRAWAL_FEE_PERCENT,
            feeAmount: fee,
            netAmount: net,
            status: "ready",
            autoApproveAt,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            createdBy: "system",
          });

          tx.set(
            rRef,
            {
              status: "funded",
              fundedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true }
          );

          tx.set(lRef, {
            type: "ROUND_FUNDED",
            groupId,
            roundId,
            roundNumber,
            requiredTotal: gross,
            receivedTotal: received,
            payoutIntentId: pRef.id,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            createdBy: "system",
          });

          console.log("[njangi] payout intent created (round funded)", {
            groupId,
            roundId,
            roundNumber,
            payeeUid,
            gross,
            fee,
            net,
          });
        }
      }
    });
  });

// ----------------------------
// 3) Auto-approve payout intents next day at 9am ET if no disputes
// ----------------------------
exports.autoApproveNjangiPayouts = functions
  .region(NJANGI_REGION)
  .pubsub.schedule("every 15 minutes")
  .timeZone(AUTO_APPROVE_TZ)
  .onRun(async () => {
    const now = admin.firestore.Timestamp.now();

    // collectionGroup query across all groups
    const snap = await firestore
      .collectionGroup("payoutIntents")
      .where("status", "==", "ready")
      .where("autoApproveAt", "<=", now)
      .limit(50)
      .get();

    if (snap.empty) {
      console.log("[njangi] autoApprove: no due payouts");
      return null;
    }

    console.log("[njangi] autoApprove: candidates", { count: snap.size });

    for (const d of snap.docs) {
      const payout = d.data() || {};
      const pRef = d.ref;

      // pRef path: njangiGroups/{groupId}/payoutIntents/{roundId}
      const groupId = pRef.parent?.parent?.id;
      const roundId = payout.roundId || pRef.id;

      if (!groupId || !roundId) {
        console.warn("[njangi] autoApprove: missing groupId/roundId", { path: pRef.path });
        continue;
      }

      // Skip if there is an open dispute for this round
      const disp = await disputesCol(groupId)
        .where("status", "==", "open")
        .where("roundId", "==", roundId)
        .limit(1)
        .get();

      if (!disp.empty) {
        console.log("[njangi] autoApprove skipped (open dispute)", { groupId, roundId, payoutId: pRef.id });
        continue;
      }

      const lRef = ledgerCol(groupId).doc();

      await firestore.runTransaction(async (tx) => {
        const fresh = await tx.get(pRef);
        if (!fresh.exists) return;

        const cur = fresh.data() || {};
        if (String(cur.status || "") !== "ready") return;

        tx.set(
          pRef,
          {
            status: "approved",
            approvedBy: "system",
            approvedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        tx.set(lRef, {
          type: "PAYOUT_APPROVED",
          groupId,
          roundId,
          payoutIntentId: pRef.id,
          grossAmount: cur.grossAmount || 0,
          feePercent: PLATFORM_WITHDRAWAL_FEE_PERCENT,
          feeAmount: cur.feeAmount || 0,
          netAmount: cur.netAmount || 0,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          createdBy: "system",
        });
      });

      console.log("[njangi] payout auto-approved", { groupId, roundId, payoutId: pRef.id });
    }

    return null;
  });

