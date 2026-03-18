// functions/njangi/withdrawals.js
/* eslint-disable no-console */

/**
 * Phase 4.5 — Club Funds Withdrawals (Stripe-authoritative)
 *
 * Collection: njangiClubWithdrawals/{withdrawalId}
 * Client writes:
 *  - request: status="requested"
 *  - admin approves: status="approved"
 *
 * This function:
 *  - locks doc => status="processing"
 *  - enforces platform fee (5%) server-side
 *  - transfers NET amount to connected account (Stripe Connect)
 *  - writes immutable ledger entry under njangiGroups/{groupId}/ledger
 *  - updates withdrawal doc => status="paid" OR "blocked"
 */

function toCents(amount) {
  const n = typeof amount === "string" ? Number(amount) : amount;
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.round(n * 100);
}

function fromCents(cents) {
  const n = Number(cents || 0);
  if (!Number.isFinite(n)) return 0;
  return n / 100;
}

function safeStr(x) {
  return typeof x === "string" ? x : x == null ? "" : String(x);
}

// Factory so you can keep index.js clean
function registerNjangiWithdrawals({ fn, firestore, requireStripe, PLATFORM_FEE_RATE }) {
  // Firestore trigger: onUpdate to detect approved transitions
  const njangiProcessClubWithdrawal = fn.firestore
    .document("njangiClubWithdrawals/{withdrawalId}")
    .onUpdate(async (change, context) => {
      const withdrawalId = context.params.withdrawalId;

      const before = change.before.data() || {};
      const after = change.after.data() || {};

      // Only act on requested/pending -> approved
      const beforeStatus = safeStr(before.status || "");
      const afterStatus = safeStr(after.status || "");

      const approvedNow =
        (beforeStatus === "requested" || beforeStatus === "pending") &&
        afterStatus === "approved";

      if (!approvedNow) return null;

      const groupId = safeStr(after.groupId);
      if (!groupId) {
        console.warn("[njangiWithdrawals] Missing groupId; blocking", withdrawalId);
        await change.after.ref.set(
          {
            status: "blocked",
            blockReason: "missing_groupId",
            blockedAt: firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        return null;
      }

      const currency = safeStr(after.currency || "USD").toLowerCase();
      const requestedByUid = safeStr(after.requestedByUid || after.requestedBy || "");
      const withdrawToUid = safeStr(after.withdrawToUid || requestedByUid);

      // Amounts
      const grossCents = toCents(after.amount);
      if (!grossCents) {
        await change.after.ref.set(
          {
            status: "blocked",
            blockReason: "invalid_amount",
            blockedAt: firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
        return null;
      }

      // Enforce platform fee (immutable server-side)
      const feeRate = Number.isFinite(Number(PLATFORM_FEE_RATE)) ? Number(PLATFORM_FEE_RATE) : 0.05;
      const feeCents = Math.max(0, Math.round(grossCents * feeRate));
      const netCents = Math.max(0, grossCents - feeCents);

      // Idempotency / lock: if already processing/paid, stop
      const docRef = change.after.ref;

      let locked = false;
      await firestore.runTransaction(async (tx) => {
        const snap = await tx.get(docRef);
        if (!snap.exists) return;

        const data = snap.data() || {};
        const st = safeStr(data.status || "");

        if (st === "processing" || st === "paid") {
          return; // already handled
        }

        // lock it
        tx.set(
          docRef,
          {
            status: "processing",
            processingAt: firestore.FieldValue.serverTimestamp(),
            feeAmount: fromCents(feeCents),
            netAmount: fromCents(netCents),
            feeRate: feeRate,
          },
          { merge: true }
        );

        locked = true;
      });

      if (!locked) return null;

      // Load payee stripe connect account id
      try {
        const payeeRef = firestore.collection("users").doc(withdrawToUid);
        const payeeSnap = await payeeRef.get();

        const payee = payeeSnap.exists ? payeeSnap.data() || {} : {};
        const acctId = safeStr(payee?.stripeConnect?.accountId || "");

        if (!acctId) {
          await docRef.set(
            {
              status: "blocked",
              blockReason: "stripe_not_connected",
              blockedAt: firestore.FieldValue.serverTimestamp(),
            },
            { merge: true }
          );
          return null;
        }

        // Execute Stripe transfer (NET) to connected account
        // Assumes funds are held on the PLATFORM Stripe balance from prior charges.
        const stripe = requireStripe();

        const idempotencyKey = `njangiClubWithdrawal_${withdrawalId}_net_${netCents}`;

        const transfer = await stripe.transfers.create(
          {
            amount: netCents,
            currency,
            destination: acctId,
            description: `Njangi Club Funds Withdrawal (net) — ${groupId}`,
            metadata: {
              kind: "njangi_club_funds_withdrawal",
              withdrawalId,
              groupId,
              gross: String(fromCents(grossCents)),
              fee: String(fromCents(feeCents)),
              net: String(fromCents(netCents)),
              requestedByUid,
              withdrawToUid,
            },
          },
          { idempotencyKey }
        );

        // Ledger entry (immutable)
        const ledgerRef = firestore
          .collection("njangiGroups")
          .doc(groupId)
          .collection("ledger")
          .doc();

        await ledgerRef.set({
          type: "club_fund_withdrawal",
          groupId,
          withdrawalId,
          currency: currency.toUpperCase(),
          grossAmount: fromCents(grossCents),
          feeAmount: fromCents(feeCents),
          netAmount: fromCents(netCents),
          feeRate,
          requestedByUid,
          withdrawToUid,
          stripeTransferId: transfer.id,
          createdAt: firestore.FieldValue.serverTimestamp(),
        });

        // Mark paid
        await docRef.set(
          {
            status: "paid",
            paidAt: firestore.FieldValue.serverTimestamp(),
            stripeTransferId: transfer.id,
          },
          { merge: true }
        );

        return null;
      } catch (e) {
        console.error("[njangiWithdrawals] Stripe transfer failed:", withdrawalId, e);

        await docRef.set(
          {
            status: "blocked",
            blockReason: "stripe_error",
            blockMessage: safeStr(e?.message || "Stripe error"),
            blockedAt: firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        return null;
      }
    });

  return { njangiProcessClubWithdrawal };
}

module.exports = { registerNjangiWithdrawals };

