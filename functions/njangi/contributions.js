// functions/njangi/contributions.js
// Handles Njangi round contributions and club "Funds" contributions.
// These are callable functions that only the client SDK (authenticated) can invoke.

const {
  db,
  functions,
  requireAuth,
  getNjangiGroupOrThrow,
  requireMember,
  ensureGroupActiveOrSetup,
  toCents,
  now,
} = require("./shared");

/**
 * Payload shape (round contribution):
 * {
 *   groupId: string,
 *   roundId?: string,
 *   roundIndex?: number,
 *   amount: number,           // in major units (e.g., 100.00)
 *   currency: string          // e.g. "USD"
 * }
 *
 * For now we do not directly hit Stripe here; we assume:
 * - Either wallet has been topped up already, or
 * - You will extend this later to check / debit wallet.
 */
exports.njangiCreateRoundContribution = functions.https.onCall(
  async (data, context) => {
    const uid = requireAuth(context);

    const groupId = String(data.groupId || "").trim();
    const amount = data.amount;
    const currency = String(data.currency || "USD").toUpperCase();
    const roundId = data.roundId ? String(data.roundId) : null;
    const roundIndex =
      typeof data.roundIndex === "number" ? data.roundIndex : null;

    if (!groupId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "groupId is required."
      );
    }
    if (!currency) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "currency is required."
      );
    }

    const amountCents = toCents(amount);

    const group = await getNjangiGroupOrThrow(groupId);
    await requireMember(groupId, uid);
    ensureGroupActiveOrSetup(group, "creating a round contribution");

    const batch = db.batch();
    const contribRef = group.ref.collection("contributions").doc();
    const ledgerRef = group.ref.collection("ledger").doc();

    const ts = now();

    const contribDoc = {
      groupId,
      userId: uid,
      type: "round", // distinguishes from "funds" contributions
      amountCents,
      currency,
      roundId: roundId || null,
      roundIndex: roundIndex,
      createdAt: ts,
      createdBy: uid,
      source: "app", // vs "admin", "import", etc.
    };

    const ledgerDoc = {
      groupId,
      kind: "contribution",
      type: "CONTRIBUTION_MANUAL",
      amount: amountCents,
      currency,
      fromUid: uid,
      toUid: null,
      roundId: roundId || null,
      roundIndex: roundIndex,
      actorUid: uid,
      note: "Njangi round contribution",
      ts,
      createdAt: ts,
      createdBy: uid,
    };

    batch.set(contribRef, contribDoc);
    batch.set(ledgerRef, ledgerDoc);

    await batch.commit();

    return {
      ok: true,
      contributionId: contribRef.id,
      ledgerEntryId: ledgerRef.id,
    };
  }
);

/**
 * Payload shape (Funds contribution):
 * {
 *   groupId: string,
 *   amount: number,       // in major units
 *   currency: string,
 *   note?: string,        // optional reason / label for the fund
 * }
 *
 * This is for the "Funds" corner: pooled money for a cause,
 * separate from Njangi rounds but still tied to the group.
 */
exports.njangiCreateFundsContribution = functions.https.onCall(
  async (data, context) => {
    const uid = requireAuth(context);

    const groupId = String(data.groupId || "").trim();
    const amount = data.amount;
    const currency = String(data.currency || "USD").toUpperCase();
    const note = data.note ? String(data.note) : "";

    if (!groupId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "groupId is required."
      );
    }
    if (!currency) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "currency is required."
      );
    }

    const amountCents = toCents(amount);

    const group = await getNjangiGroupOrThrow(groupId);
    await requireMember(groupId, uid);
    ensureGroupActiveOrSetup(group, "contributing to club funds");

    const batch = db.batch();
    const contribRef = group.ref.collection("contributions").doc();
    const ledgerRef = group.ref.collection("ledger").doc();

    const ts = now();

    const contribDoc = {
      groupId,
      userId: uid,
      type: "funds", // distinguish from "round"
      amountCents,
      currency,
      note: note || "Club funds contribution",
      createdAt: ts,
      createdBy: uid,
      source: "app",
    };

    const ledgerDoc = {
      groupId,
      kind: "funds",
      type: "CONTRIBUTION_MANUAL",
      amount: amountCents,
      currency,
      fromUid: uid,
      toUid: null,
      actorUid: uid,
      note: note || "Club funds contribution",
      ts,
      createdAt: ts,
      createdBy: uid,
    };

    batch.set(contribRef, contribDoc);
    batch.set(ledgerRef, ledgerDoc);

    await batch.commit();

    return {
      ok: true,
      contributionId: contribRef.id,
      ledgerEntryId: ledgerRef.id,
    };
  }
);

