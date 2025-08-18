// functions/nightlife.js
module.exports = (functions, admin) => {
  const db = admin.database();

  // -----------------------------
  // CREATE RESERVATION HOLD (CALLABLE)
  // -----------------------------
  const createReservationHold = functions.https.onCall(async (data, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Login required');
    const { nightId, tableId, minSpend, depositPercent = 0 } = data || {};
    if (!nightId || !tableId || typeof minSpend !== 'number') {
      throw new functions.https.HttpsError('invalid-argument', 'nightId, tableId, minSpend required');
    }

    const now = Date.now();
    const holdMs = 10 * 60 * 1000; // 10 minutes
    const holdExpiresAt = now + holdMs;

    const invRef = db.ref(`inventory/${nightId}/${tableId}`);
    const invSnap = await invRef.get();
    if (!invSnap.exists()) throw new functions.https.HttpsError('not-found', 'Inventory not found');
    const inv = invSnap.val();
    if (inv.status && inv.status !== 'available') {
      throw new functions.https.HttpsError('failed-precondition', 'Table not available');
    }

    const reservationRef = db.ref('reservations').push();
    const reservationId = reservationRef.key;
    const depositAmount = Math.round((minSpend * (depositPercent / 100)) * 100) / 100;

    await Promise.all([
      invRef.update({
        status: 'held',
        holdReservationId: reservationId,
        holdExpiresAt
      }),
      reservationRef.set({
        id: reservationId,
        nightId,
        tableId,
        userId: context.auth.uid,
        status: 'held',
        minSpend,
        depositPercent,
        depositAmount,
        amountPaid: 0,
        createdAt: now,
        holdExpiresAt
      })
    ]);

    return { reservationId, holdExpiresAt, depositAmount };
  });

  // -----------------------------
  // EXPIRE HOLDS (SCHEDULED)
  // -----------------------------
  const expireHolds = functions
    .pubsub.schedule('every 5 minutes')
    .timeZone('Etc/UTC')
    .onRun(async () => {
      const now = Date.now();
      const held = await db.ref('reservations').orderByChild('status').equalTo('held').get();
      const updates = {};
      held.forEach(child => {
        const r = child.val();
        if (r.holdExpiresAt && r.holdExpiresAt < now) {
          updates[`reservations/${child.key}/status`] = 'expired';
          updates[`inventory/${r.nightId}/${r.tableId}/status`] = 'available';
          updates[`inventory/${r.nightId}/${r.tableId}/holdReservationId`] = null;
          updates[`inventory/${r.nightId}/${r.tableId}/holdExpiresAt`] = null;
        }
      });
      if (Object.keys(updates).length) await db.ref().update(updates);
      return null;
    });

  // -----------------------------
  // CONFIRM PAYMENT (CALLABLE)
  // -----------------------------
  const confirmPaymentNightlife = functions.https.onCall(async (data, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Login required');
    const { reservationId, amountPaid, promoterId = null } = data || {};
    if (!reservationId || typeof amountPaid !== 'number') {
      throw new functions.https.HttpsError('invalid-argument', 'reservationId and amountPaid required');
    }

    const resRef = db.ref(`reservations/${reservationId}`);
    const snap = await resRef.get();
    if (!snap.exists()) throw new functions.https.HttpsError('not-found', 'Reservation not found');
    const r = snap.val();

    const updates = {
      [`reservations/${reservationId}/status`]: 'paid',
      [`reservations/${reservationId}/amountPaid`]: amountPaid,
      [`inventory/${r.nightId}/${r.tableId}/status`]: 'paid',
      [`inventory/${r.nightId}/${r.tableId}/holdReservationId`]: null,
      [`inventory/${r.nightId}/${r.tableId}/holdExpiresAt`]: null
    };
    if (promoterId) updates[`reservations/${reservationId}/promoterId`] = promoterId;

    await db.ref().update(updates);
    return { ok: true };
  });

  // ======================================================================
  // AGDASHBOARD: APPLICATIONS MGMT (LIST / APPROVE / REJECT) — CALLABLES
  // ======================================================================

  /**
   * List Nightlife Applications
   * data: { type: "promoter" | "venue", status?: "pending" | "approved" | "rejected", limit?: number }
   * returns: { items: [{ uid, ...payload }], count }
   */
  const listNightlifeApplications = functions.https.onCall(async (data, _context) => {
    const type = (data && data.type) === 'venue' ? 'venue' : 'promoter';
    const statusFilter = data && data.status; // optional
    const limit = Math.min(parseInt((data && data.limit) || 50, 10) || 50, 200);

    const node = type === 'venue' ? 'venueApplications' : 'promoterApplications';
    const snap = await db.ref(node).limitToFirst(limit).get();

    const items = [];
    snap.forEach(child => {
      const val = child.val() || {};
      if (!statusFilter || val.status === statusFilter) {
        items.push({ uid: child.key, ...val });
      }
    });

    return { items, count: items.length };
  });

  /**
   * Review (Approve/Reject) Nightlife Application
   * data: {
   *   type: "promoter" | "venue",
   *   uid: string,
   *   action: "approve" | "reject",
   *   reason?: string,
   *   venue?: { venueId?: string, name?: string, address?: string }, // only used for type === "venue"
   *   reviewerId?: string
   * }
   */
  const reviewNightlifeApplication = functions.https.onCall(async (data, _context) => {
    const { type, uid, action } = data || {};
    if (!type || !uid || !action) {
      throw new functions.https.HttpsError('invalid-argument', 'Missing required fields: type, uid, action');
    }

    const appNode = type === 'venue' ? 'venueApplications' : 'promoterApplications';
    const destNode = type === 'venue' ? 'venues' : 'promoters';

    const appRef = db.ref(`${appNode}/${uid}`);
    const appSnap = await appRef.get();
    if (!appSnap.exists()) throw new functions.https.HttpsError('not-found', `Application not found for ${type} uid=${uid}`);
    const app = appSnap.val() || {};
    const now = Date.now();

    if (action === 'reject') {
      const reason = data.reason || 'Not specified';
      await appRef.update({
        status: 'rejected',
        approved: false,
        reviewedAt: now,
        reviewReason: reason
      });

      await db.ref('activityLogs').push({
        type: 'nightlife_application_reject',
        targetType: type,
        targetUid: uid,
        reason,
        reviewerId: data.reviewerId || null,
        ts: admin.database.ServerValue.TIMESTAMP
      });

      return { ok: true, action: 'rejected' };
    }

    if (action === 'approve') {
      // Build destination profile
      const profile = {
        uid,
        approved: true,
        approvedAt: now,
        sourceApplication: appNode,
        fullName: app.fullName || '',
        email: app.email || '',
        phone: app.phone || '',
        businessName: app.businessName || '',
        website: app.website || '',
        instagram: app.instagram || '',
        tiktok: app.tiktok || '',
        description: app.description || ''
      };

      // Write to /promoters/{uid} OR /venues/{uid}
      const destRef = db.ref(`${destNode}/${uid}`);
      await destRef.update(profile);

      // Mark application approved
      await appRef.update({
        status: 'approved',
        approved: true,
        reviewedAt: now
      });

      // Optional: Venue enrichment & admin mapping
      if (type === 'venue' && data.venue && data.venue.venueId) {
        const venueId = String(data.venue.venueId);

        // Link this user as venue admin
        await db.ref(`venueAdmins/${venueId}/${uid}`).set(true);

        // Seed /venues/{venueId} if missing
        const venueRef = db.ref(`venues/${venueId}`);
        const venueSnap = await venueRef.get();
        if (!venueSnap.exists()) {
          await venueRef.set({
            id: venueId,
            name: data.venue.name || app.businessName || 'New Venue',
            address: data.venue.address || '',
            createdAt: now
          });
        }
      }

      // Activity log
      await db.ref('activityLogs').push({
        type: 'nightlife_application_approve',
        targetType: type,
        targetUid: uid,
        reviewerId: data.reviewerId || null,
        ts: admin.database.ServerValue.TIMESTAMP
      });

      return { ok: true, action: 'approved' };
    }

    throw new functions.https.HttpsError('invalid-argument', 'Unsupported action');
  });

  // -----------------------------
  // EXPORTS
  // -----------------------------
  return {
    // Existing functions
    createReservationHold,
    expireHolds,
    confirmPaymentNightlife,

    // New AGDashboard callables
    listNightlifeApplications,
    reviewNightlifeApplication
  };
};
