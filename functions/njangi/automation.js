// functions/njangi/automation.js
/* eslint-disable no-console */

module.exports = (deps) => {
  const { functions, admin } = deps;

  const fn = functions.region("us-central1");
  const firestore = admin.firestore();

  const TZ = "America/New_York";
  const BATCH_LIMIT = 50; // keep small & safe; cron runs often

  // SCHEDULE: every 10 minutes; approves anything due at/after 9am ET (and later)
  // If you want more/less frequent, change "every 10 minutes".
  const njangiAutoApprovePayouts = fn.pubsub
    .schedule("every 10 minutes")
    .timeZone(TZ)
    .onRun(async () => {
      const stamp = new Date().toISOString();
      console.log(`🕓 [njangiAutoApprovePayouts] tick ${stamp} TZ=${TZ}`);

      const now = admin.firestore.Timestamp.now();

      // We approve payout intents that are "pending_auto" and autoApproveAt <= now
      // NOTE: ensure your payout intent docs have these fields:
      // - status: "pending_auto"
      // - autoApproveAt: Timestamp
      // - groupId: string
      // - roundId: string (optional but recommended)
      // - payoutIntentId: string (optional; doc id usually used)
      //
      // Collection path: njangiGroups/{groupId}/payoutIntents/{payoutId}
      // We'll use a collectionGroup query.
      const q = firestore
        .collectionGroup("payoutIntents")
        .where("status", "==", "pending_auto")
        .where("autoApproveAt", "<=", now)
        .limit(BATCH_LIMIT);

      const snap = await q.get();
      if (snap.empty) {
        console.log("✅ No due payout intents to auto-approve.");
        return null;
      }

      console.log(`➡️ Found ${snap.size} due payout intents (limit ${BATCH_LIMIT}).`);

      let approvedCount = 0;
      let skippedDispute = 0;
      let skippedBad = 0;

      // Process sequentially to keep logs clear (safe + simple)
      for (const docSnap of snap.docs) {
        const p = docSnap.data() || {};
        const payoutId = docSnap.id;

        const groupId = String(p.groupId || "").trim();
        if (!groupId) {
          console.warn("⚠️ Skipping payout intent missing groupId:", payoutId);
          skippedBad++;
          continue;
        }

        const roundId = String(p.roundId || payoutId).trim();

        const groupRef = firestore.collection("njangiGroups").doc(groupId);
        const payoutRef = groupRef.collection("payoutIntents").doc(payoutId);

        // Dispute gate: if any OPEN dispute exists for this payoutIntentId OR this roundId => skip.
        // Disputes path: njangiGroups/{groupId}/disputes/{disputeId}
        // Fields: status == "open", payoutIntentId, roundId
        const disputesRef = groupRef.collection("disputes");

        const [byPayout, byRound] = await Promise.all([
          disputesRef
            .where("status", "==", "open")
            .where("payoutIntentId", "==", payoutId)
            .limit(1)
            .get(),
          disputesRef
            .where("status", "==", "open")
            .where("roundId", "==", roundId)
            .limit(1)
            .get(),
        ]);

        const hasOpenDispute = !byPayout.empty || !byRound.empty;
        if (hasOpenDispute) {
          console.log(`⛔ Dispute open; skipping auto-approval. group=${groupId} payout=${payoutId} round=${roundId}`);
          skippedDispute++;
          continue;
        }

        // Transaction: approve only if still pending_auto (idempotent)
        await firestore.runTransaction(async (tx) => {
          const cur = await tx.get(payoutRef);
          if (!cur.exists) return;

          const d = cur.data() || {};
          if (d.status !== "pending_auto") return; // already handled elsewhere

          // Update payout status
          tx.update(payoutRef, {
            status: "approved",
            approvedAt: admin.firestore.FieldValue.serverTimestamp(),
            approvedBy: "auto",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          // Immutable ledger entry
          const ledgerRef = groupRef.collection("ledger").doc();
          tx.set(ledgerRef, {
            id: ledgerRef.id,
            type: "PAYOUT_AUTO_APPROVED",
            groupId,
            payoutIntentId: payoutId,
            roundId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            createdBy: "auto",
          });
        });

        approvedCount++;
        console.log(`✅ Auto-approved payout. group=${groupId} payout=${payoutId}`);
      }

      console.log(
        `🏁 Done. approved=${approvedCount} skippedDispute=${skippedDispute} skippedBad=${skippedBad}`
      );

      return null;
    });

  return { njangiAutoApprovePayouts };
};

