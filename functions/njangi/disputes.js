// functions/njangi/disputes.js
/* eslint-disable no-console */
const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

const firestore = admin.firestore();
const NJANGI_REGION = "us-central1";

/**
 * Disputes design:
 * - Disputes live at: njangiGroups/{groupId}/disputes/{disputeId}
 * - Dispute must reference either:
 *   - payoutIntentId (recommended; equals roundId in your current payout doc scheme)
 *   - or roundId
 * - Only ONE open dispute per payoutIntent/round should exist
 * - Auto-approval already checks disputes where status=="open" and roundId==roundId
 *   so we always set roundId for compatibility.
 */

function mustSignedIn(context) {
  if (!context.auth || !context.auth.uid) throw new functions.https.HttpsError("unauthenticated", "Sign-in required.");
  return context.auth.uid;
}

function cleanStr(s, max = 400) {
  return String(s || "").trim().slice(0, max);
}

function groupDoc(groupId) {
  return firestore.doc(`njangiGroups/${groupId}`);
}
function memberDoc(groupId, uid) {
  return firestore.doc(`njangiGroups/${groupId}/members/${uid}`);
}
function payoutDoc(groupId, payoutIntentId) {
  return firestore.doc(`njangiGroups/${groupId}/payoutIntents/${payoutIntentId}`);
}
function disputeCol(groupId) {
  return firestore.collection(`njangiGroups/${groupId}/disputes`);
}
function ledgerCol(groupId) {
  return firestore.collection(`njangiGroups/${groupId}/ledger`);
}

async function isAdminOrOwner(groupId, uid) {
  const m = await memberDoc(groupId, uid).get();
  if (!m.exists) return false;
  const role = String((m.data() || {}).role || "member");
  return role === "owner" || role === "admin";
}

async function isMember(groupId, uid) {
  const m = await memberDoc(groupId, uid).get();
  return m.exists && String((m.data() || {}).status || "active") !== "removed";
}

/**
 * Callable: Open dispute
 * payload: { groupId, payoutIntentId, reason }
 * - validates member
 * - ensures payout intent exists
 * - ensures no open dispute exists for that payout/round
 * - creates dispute + ledger event
 * - updates payout intent status to "paused" (optional UX clarity)
 */
exports.njangiOpenDispute = functions
  .region(NJANGI_REGION)
  .https.onCall(async (data, context) => {
    const uid = mustSignedIn(context);

    const groupId = cleanStr(data?.groupId, 120);
    const payoutIntentId = cleanStr(data?.payoutIntentId, 120);
    const reason = cleanStr(data?.reason, 800);

    if (!groupId) throw new functions.https.HttpsError("invalid-argument", "Missing groupId.");
    if (!payoutIntentId) throw new functions.https.HttpsError("invalid-argument", "Missing payoutIntentId.");
    if (!reason) throw new functions.https.HttpsError("invalid-argument", "Please include a reason.");

    // Must be a member
    if (!(await isMember(groupId, uid))) {
      throw new functions.https.HttpsError("permission-denied", "Only group members can open disputes.");
    }

    const pRef = payoutDoc(groupId, payoutIntentId);
    const gRef = groupDoc(groupId);
    const dRef = disputeCol(groupId).doc();
    const lRef = ledgerCol(groupId).doc();

    await firestore.runTransaction(async (tx) => {
      const gSnap = await tx.get(gRef);
      if (!gSnap.exists) throw new functions.https.HttpsError("not-found", "Group not found.");

      const pSnap = await tx.get(pRef);
      if (!pSnap.exists) throw new functions.https.HttpsError("not-found", "Payout intent not found.");

      const p = pSnap.data() || {};
      const roundId = String(p.roundId || payoutIntentId); // ensure compatibility with your auto-approve query

      // Enforce single open dispute per round/payout
      const openQ = await tx.get(
        disputeCol(groupId)
          .where("status", "==", "open")
          .where("roundId", "==", roundId)
          .limit(1)
      );
      if (!openQ.empty) {
        throw new functions.https.HttpsError("failed-precondition", "An open dispute already exists for this payout/round.");
      }

      // Create dispute
      tx.set(dRef, {
        groupId,
        roundId,
        payoutIntentId,
        reason,
        status: "open",
        openedBy: uid,
        openedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Optional: mark payout as paused for UI clarity (auto-approve checks disputes anyway)
      tx.set(
        pRef,
        {
          status: "paused",
          pausedBy: uid,
          pausedAt: admin.firestore.FieldValue.serverTimestamp(),
          pausedReason: reason.slice(0, 300),
        },
        { merge: true }
      );

      // Ledger event
      tx.set(lRef, {
        type: "DISPUTE_OPENED",
        groupId,
        roundId,
        payoutIntentId,
        disputeId: dRef.id,
        reason: reason.slice(0, 800),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: uid,
      });
    });

    console.log("[njangi] dispute opened", { groupId, payoutIntentId, openedBy: uid });
    return { ok: true, disputeId: dRef.id };
  });

/**
 * Callable: Resolve dispute (admin/owner)
 * payload: { groupId, disputeId, resolutionNote, action }
 * action: "dismiss" | "resolve_resume" | "resolve_keep_paused"
 *
 * - dismiss: closes dispute, does NOT change payout status
 * - resolve_resume: closes dispute AND sets payoutIntent.status back to "ready"
 *   (auto-approve can proceed at next schedule if autoApproveAt passed and no open disputes)
 * - resolve_keep_paused: closes dispute but keeps payout paused (admin will decide later)
 */
exports.njangiResolveDispute = functions
  .region(NJANGI_REGION)
  .https.onCall(async (data, context) => {
    const uid = mustSignedIn(context);

    const groupId = cleanStr(data?.groupId, 120);
    const disputeId = cleanStr(data?.disputeId, 120);
    const resolutionNote = cleanStr(data?.resolutionNote, 800);
    const action = cleanStr(data?.action, 60) || "resolve_resume";

    if (!groupId) throw new functions.https.HttpsError("invalid-argument", "Missing groupId.");
    if (!disputeId) throw new functions.https.HttpsError("invalid-argument", "Missing disputeId.");

    const isAdmin = await isAdminOrOwner(groupId, uid);
    if (!isAdmin) throw new functions.https.HttpsError("permission-denied", "Admin/Owner only.");

    const dRef = firestore.doc(`njangiGroups/${groupId}/disputes/${disputeId}`);
    const lRef = ledgerCol(groupId).doc();

    await firestore.runTransaction(async (tx) => {
      const dSnap = await tx.get(dRef);
      if (!dSnap.exists) throw new functions.https.HttpsError("not-found", "Dispute not found.");

      const d = dSnap.data() || {};
      if (String(d.status || "") !== "open") {
        throw new functions.https.HttpsError("failed-precondition", "Dispute is not open.");
      }

      const payoutIntentId = String(d.payoutIntentId || d.roundId || "");
      const roundId = String(d.roundId || payoutIntentId || "");

      // Close dispute
      tx.set(
        dRef,
        {
          status: "closed",
          closedBy: uid,
          closedAt: admin.firestore.FieldValue.serverTimestamp(),
          resolutionNote,
          resolutionAction: action,
        },
        { merge: true }
      );

      // Optional payout state handling
      if (payoutIntentId) {
        const pRef = payoutDoc(groupId, payoutIntentId);

        if (action === "resolve_resume") {
          // Set back to "ready" only if not already approved/paid/cancelled
          const pSnap = await tx.get(pRef);
          if (pSnap.exists) {
            const p = pSnap.data() || {};
            const ps = String(p.status || "ready");
            if (ps === "paused") {
              tx.set(
                pRef,
                {
                  status: "ready",
                  resumedBy: uid,
                  resumedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                { merge: true }
              );
            }
          }
        }
        // resolve_keep_paused: do nothing
        // dismiss: do nothing
      }

      // Ledger
      tx.set(lRef, {
        type: "DISPUTE_CLOSED",
        groupId,
        roundId,
        payoutIntentId,
        disputeId,
        action,
        note: resolutionNote.slice(0, 800),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: uid,
      });
    });

    console.log("[njangi] dispute closed", { groupId, disputeId, closedBy: uid, action });
    return { ok: true };
  });

