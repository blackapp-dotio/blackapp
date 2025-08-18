// functions/index.js
/* eslint-disable no-console */
const admin = require("firebase-admin");
const braintree = require("braintree");
const corsMw = require("cors")({ origin: true });
const functions = require("firebase-functions/v1"); // v1 API (region helper below)

// Prefer global fetch (Node 18+), else lazy import node-fetch
const fetch =
  typeof globalThis.fetch === "function"
    ? globalThis.fetch
    : (...args) => import("node-fetch").then(({ default: f }) => f(...args));

// --- Admin init (single place) ---
if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.applicationDefault(),
    databaseURL: "https://blackappios-default-rtdb.firebaseio.com",
  });
}

// --- Regioned functions instance ---
const fn = functions.region("us-central1");
const db = admin.database();

// ---------- Runtime config for external feeds ----------
const cfg = (() => {
  const c = {};
  try {
    Object.assign(c, functions.config());
  } catch (_) {
    // In emulator or if no config set, functions.config() may be empty
  }
  return c;
})();

const TM_API_KEY = process.env.TM_API_KEY || (cfg.tm && cfg.tm.key) || "";
const EVENTBRITE_TOKEN =
  process.env.EVENTBRITE_TOKEN || (cfg.eventbrite && cfg.eventbrite.token) || "";

// ---------- Small helpers ----------
const withCors = (handler) => (req, res) =>
  corsMw(req, res, () => handler(req, res));

const q = (req, name) => {
  const v = req.query && req.query[name];
  return typeof v === "string" && v.trim() ? v.trim() : undefined;
};

const qDate = (req, name) => {
  const s = q(req, name);
  if (!s) return undefined;
  const d = new Date(s);
  return isNaN(d.getTime()) ? undefined : d;
};

const toISO8601UTC = (d) => new Date(d.toISOString()).toISOString();

const clampDateWindow = (start, end) => {
  const now = new Date();
  const s = start || now;
  const e = end || new Date(now.getTime() + 14 * 24 * 60 * 60 * 1000);
  return { start: s, end: e };
};

const safeNumber = (n) => {
  if (typeof n === "number" && isFinite(n)) return n;
  if (typeof n === "string") {
    const x = Number(n);
    if (isFinite(x)) return x;
  }
  return undefined;
};

const joinAddress = (parts) =>
  parts
    .filter((p) => !!p && String(p).trim() !== "")
    .map((p) => String(p).trim())
    .join(", ");

// --- Braintree gateway ---
const gateway = new braintree.BraintreeGateway({
  environment: braintree.Environment.Sandbox,
  merchantId: "bv3gft4qcdkrznn2",
  publicKey: "869df6w9p4pks5ch",
  privateKey: "2703c4d9fc5a3e1e9ec7fde9641a2951",
});

// =========================
// Existing HTTPS endpoints
// =========================

exports.generateClientToken = fn.https.onRequest(
  withCors(async (_req, res) => {
    try {
      const response = await gateway.clientToken.generate({});
      res.status(200).send({ clientToken: response.clientToken });
    } catch (error) {
      console.error("❌ Token generation failed:", error);
      res.status(500).send({ error: "Token generation failed" });
    }
  })
);

exports.createTransaction = fn.https.onRequest(
  withCors(async (req, res) => {
    const {
      paymentMethodNonce,
      userId,
      eventId,
      eventName,
      eventImagePath = "",
      ticketQty = 0,
      ticketPrice = 0,
      tableQty = 0,
      tablePrice = 0,
      platformFee = 0,
      totalWithFee = 0,
      eventTime,
    } = req.body;

    console.log("📥 Incoming request body:", req.body);

    const ticketQtyNum = parseInt(ticketQty) || 0;
    const tableQtyNum = parseInt(tableQty) || 0;
    const ticketPriceNum = parseFloat(ticketPrice) || 0;
    const tablePriceNum = parseFloat(tablePrice) || 0;
    let amountToCharge = parseFloat(totalWithFee);

    const fallbackBase =
      ticketQtyNum * ticketPriceNum + tableQtyNum * tablePriceNum;
    const fallbackFee = +(fallbackBase * 0.02).toFixed(2);
    const fallbackTotal = +(fallbackBase + fallbackFee).toFixed(2);

    if (isNaN(amountToCharge) || amountToCharge <= 0) {
      console.warn(
        "⚠️ Invalid totalWithFee from frontend. Falling back to server-calculated total."
      );
      amountToCharge = fallbackTotal;
    }

    if (!paymentMethodNonce || !userId || !eventId || !eventName) {
      return res.status(400).send({ error: "❌ Missing required fields" });
    }

    const totalQty = ticketQtyNum + tableQtyNum;
    let type = "ticket";
    if (ticketQtyNum > 0 && tableQtyNum > 0) type = "mixed";
    else if (tableQtyNum > 0 && ticketQtyNum === 0) type = "table";

    console.log(
      "🧮 Totals => Base:",
      fallbackBase.toFixed(2),
      "Fee:",
      fallbackFee.toFixed(2),
      "Charged:",
      amountToCharge.toFixed(2)
    );

    try {
      const result = await gateway.transaction.sale({
        amount: amountToCharge.toFixed(2),
        paymentMethodNonce,
        options: { submitForSettlement: true },
      });

      if (!result.success)
        throw new Error(result.message || "Transaction unsuccessful");

      const timestamp = Math.floor(Date.now() / 1000);
      const purchaseRef = admin.database().ref(`purchases/${userId}`).push();

      await purchaseRef.set({
        id: purchaseRef.key,
        userId,
        eventId,
        eventTitle: eventName,
        eventImagePath,
        quantity: totalQty,
        type,
        ticketQty: ticketQtyNum,
        ticketPrice: ticketPriceNum,
        tableQty: tableQtyNum,
        tablePrice: tablePriceNum,
        baseAmount: fallbackBase,
        platformFee: fallbackFee,
        totalAmount: amountToCharge,
        timestamp,
        eventTime: eventTime ? parseInt(eventTime) : null,
        paymentMethod: "card",
      });

      console.log("✅ Transaction successful:", result.transaction.id);
      res.status(200).send({
        success: true,
        transactionId: result.transaction.id,
      });
    } catch (error) {
      console.error("❌ Transaction failed:", error);
      res.status(500).send({ error: error.message || "Unknown server error" });
    }
  })
);

// Runs hourly to look 24h ahead for reminders (region pinned)
exports.scheduleEventReminders = fn.pubsub
  .schedule("every 1 hours")
  .onRun(async () => {
    const now = Date.now();
    const snapshot = await admin.database().ref("purchases").once("value");

    snapshot.forEach((userSnap) => {
      userSnap.forEach((purchaseSnap) => {
        const data = purchaseSnap.val();
        const { eventTime, eventName = "Event", eventId, userId } = data;

        if (!eventTime || !userId) return;

        const diff = eventTime - now;
        const isNextHour = diff > 0 && diff < 60 * 60 * 1000; // within next hour

        if (isNextHour) {
          admin
            .database()
            .ref(`users/${userId}/onesignalUserId`) // normalized path
            .once("value")
            .then((tokenSnap) => {
              const oneSignalId = tokenSnap.val();
              if (!oneSignalId) return;

              const payload = {
                app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
                include_player_ids: [oneSignalId],
                headings: { en: "🎉 Event Reminder" },
                contents: { en: `Your event "${eventName}" is in 24 hours.` },
                data: { type: "event_reminder", eventId, eventName },
              };

              return fetch("https://onesignal.com/api/v1/notifications", {
                method: "POST",
                headers: {
                  "Content-Type": "application/json",
                  Authorization:
                    "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
                },
                body: JSON.stringify(payload),
              });
            });
        }
      });
    });

    return null;
  });

exports.getPlatformRevenue = fn.https.onRequest(
  withCors(async (_req, res) => {
    try {
      const snapshot = await admin.database().ref("purchases").once("value");

      let totalRevenue = 0;
      let platformEarnings = 0;
      let totalEvents = new Set();
      let ticketsSold = 0;

      snapshot.forEach((userSnap) => {
        userSnap.forEach((purchaseSnap) => {
          const data = purchaseSnap.val();

          const userId = data.userId;
          const eventId = data.eventId;
          const total = parseFloat(data.totalAmount) || 0;
          const fee = parseFloat(data.platformFee) || 0;
          const qty = parseInt(data.ticketQty) || 0;

          if (!userId || !eventId || isNaN(total) || total <= 0) {
            console.warn("❌ Skipping invalid purchase:", {
              userId,
              eventId,
              total,
              fee,
              qty,
            });
            return;
          }

          totalEvents.add(eventId);
          platformEarnings += fee;
          totalRevenue += total;
          ticketsSold += qty;
        });
      });

      res.status(200).send({
        platformEarnings: platformEarnings.toFixed(2),
        totalRevenue: totalRevenue.toFixed(2),
        totalEvents: totalEvents.size,
        ticketsSold,
      });
    } catch (err) {
      console.error("❌ Revenue summary failed:", err);
      res.status(500).send({ error: err.message });
    }
  })
);

exports.getCheckoutURL = fn.https.onRequest(
  withCors((req, res) => {
    const { amount, description } = req.query;
    if (!amount || !description)
      return res
        .status(400)
        .send({ error: "Missing amount or description" });
    const redirectURL = `https://blackappios.web.app/?amount=${amount}&desc=${encodeURIComponent(
      description
    )}`;
    res.status(200).send({ checkoutURL: redirectURL });
  })
);

// Helper for logging
function logStamp(tag) {
  console.log(`🕓 [${new Date().toISOString()}] ${tag}`);
}

// =========================
/* Firestore + RTDB triggers */
// =========================

exports.sendNewMessageNotification = fn.firestore
  .document("directChats/{chatId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Direct chat trigger");

    const data = snap.data();
    const { senderId, recipientId, text = "New message" } = data;
    const chatId = context.params.chatId;

    if (!recipientId || !senderId) {
      console.warn("❌ Missing recipientId or senderId in message data");
      return;
    }

    const tokenSnap = await admin
      .database()
      .ref(`users/${recipientId}/onesignalUserId`)
      .once("value");
    const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
    if (!oneSignalId) return;

    let senderName = "Someone";
    try {
      const senderSnap = await admin
        .database()
        .ref(`users/${senderId}/name`)
        .once("value");
      if (senderSnap.exists()) senderName = senderSnap.val();
    } catch {}

    const payload = {
      app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
      include_player_ids: [oneSignalId],
      headings: { en: `New message from ${senderName}` },
      contents: { en: text.substring(0, 100) },
      data: { chatId, senderId, senderName, type: "chat" },
    };

    try {
      const response = await fetch(
        "https://onesignal.com/api/v1/notifications",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization:
              "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
          },
          body: JSON.stringify(payload),
        }
      );
      console.log("📤 Notification sent (direct):", await response.json());
    } catch (err) {
      console.error("🔥 Failed to send direct notification:", err);
    }
  });

exports.sendNewGroupMessageNotification = fn.firestore
  .document("groups/{groupId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Group message trigger");

    const data = snap.data();
    const { senderId, text = "New group message" } = data;
    const groupId = context.params.groupId;

    let senderName = "Someone";
    try {
      const senderSnap = await admin
        .firestore()
        .collection("users")
        .doc(senderId)
        .get();
      if (senderSnap.exists) senderName = senderSnap.data().name || "Someone";
    } catch {}

    let memberIds = [];
    try {
      const membersSnap = await admin
        .firestore()
        .collection(`groups/${groupId}/members`)
        .get();
      memberIds = membersSnap.docs.map((doc) => doc.id);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await admin
          .database()
          .ref(`users/${userId}/onesignalUserId`)
          .once("value");
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
        if (!oneSignalId) continue;

        const payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: `New message from ${senderName}` },
          contents: { en: text.substring(0, 100) },
          data: { groupId, senderId, senderName, type: "group" },
        };

        const response = await fetch(
          "https://onesignal.com/api/v1/notifications",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization:
                "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
            },
            body: JSON.stringify(payload),
          }
        );
        console.log(`📤 Notification sent to ${userId}:`, await response.json());
      } catch (err) {
        console.error(`🔥 Failed to notify ${userId}:`, err);
      }
    }
  });

exports.sendGroupMessageLikeNotification = fn.firestore
  .document("groups/{groupId}/messages/{messageId}")
  .onUpdate(async (change, context) => {
    logStamp("📡 OneSignal: Group like trigger");

    const before = change.before.data();
    const after = change.after.data();

    const beforeLikes = before.likes || [];
    const afterLikes = after.likes || [];
    const newLikes = afterLikes.filter((uid) => !beforeLikes.includes(uid));
    if (newLikes.length === 0) return;

    const senderId = newLikes[0];
    const { groupId, messageId } = context.params;

    let memberIds = [];
    try {
      const membersSnap = await admin
        .firestore()
        .collection(`groups/${groupId}/members`)
        .get();
      memberIds = membersSnap.docs.map((doc) => doc.id);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await admin
          .database()
          .ref(`users/${userId}/onesignalUserId`)
          .once("value");
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
        if (!oneSignalId) continue;

        const payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: "❤️ A message was liked!" },
          contents: { en: "Tap to view the liked message." },
          data: { groupId, messageId, type: "group_like" },
        };

        const response = await fetch(
          "https://onesignal.com/api/v1/notifications",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization:
                "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
            },
            body: JSON.stringify(payload),
          }
        );
        console.log(
          `📤 Like notification sent to ${userId}:`,
          await response.json()
        );
      } catch (err) {
        console.error(`🔥 Failed to send like notification to ${userId}:`, err);
      }
    }
  });

exports.sendGroupMessageCommentNotification = fn.firestore
  .document("groups/{groupId}/messages/{messageId}/comments/{commentId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Group comment trigger");

    const { groupId, messageId } = context.params;
    const comment = snap.data();
    const senderId = comment.userId;
    const commentText = comment.text || "New comment";

    let memberIds = [];
    try {
      const membersSnap = await admin
        .firestore()
        .collection(`groups/${groupId}/members`)
        .get();
      memberIds = membersSnap.docs.map((doc) => doc.id);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await admin
          .database()
          .ref(`users/${userId}/onesignalUserId`)
          .once("value");
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
        if (!oneSignalId) continue;

        const payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: "💬 New Comment in Group Chat" },
          contents: { en: commentText.substring(0, 100) },
          data: { groupId, messageId, type: "group_comment" },
        };

        const response = await fetch(
          "https://onesignal.com/api/v1/notifications",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization:
                "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
            },
            body: JSON.stringify(payload),
          }
        );
        console.log(
          `📤 Comment notification sent to ${userId}:`,
          await response.json()
        );
      } catch (err) {
        console.error(`🔥 Failed to send comment notification to ${userId}:`, err);
      }
    }
  });

exports.sendEventReminderNotification = fn.database
  .ref("purchases/{userId}/{purchaseId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Event reminder trigger");

    const { userId } = context.params;
    const data = snap.val();
    const { eventName = "Your Event", eventId, eventTime } = data;

    const tokenSnap = await admin
      .database()
      .ref(`users/${userId}/onesignalUserId`) // normalized
      .once("value");
    const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
    if (!oneSignalId) return;

    const payload = {
      app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
      include_player_ids: [oneSignalId],
      headings: { en: "🎟 Event Reminder" },
      contents: { en: `Don't miss ${eventName}! It starts soon.` },
      data: { eventId, eventName, eventTime, type: "event_reminder" },
    };

    try {
      const response = await fetch(
        "https://onesignal.com/api/v1/notifications",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization:
              "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq",
          },
          body: JSON.stringify(payload),
        }
      );
      console.log(`📤 Event reminder sent to ${userId}:`, await response.json());
    } catch (err) {
      console.error(`🔥 Event reminder failed for ${userId}:`, err);
    }
  });

exports.logManualPurchase = fn.https.onRequest(
  withCors(async (req, res) => {
    const {
      userId,
      eventId,
      eventName,
      eventImagePath = "",
      ticketQty = 0,
      ticketPrice = 0,
      tableQty = 0,
      tablePrice = 0,
      baseTotal = 0,
      totalWithFee = 0,
      payoutMethod = "",
      payoutDetails = "",
      platformFee = 0,
      timestamp = Date.now(),
      paymentMethod = "manual",
      eventTime,
    } = req.body;

    if (!userId || !eventId || !eventName) {
      return res.status(400).send({ error: "❌ Missing required fields" });
    }

    const ticketQtyNum = parseInt(ticketQty) || 0;
    const tableQtyNum = parseInt(tableQty) || 0;
    const ticketPriceNum = parseFloat(ticketPrice) || 0;
    const tablePriceNum = parseFloat(tablePrice) || 0;
    const baseAmountNum = parseFloat(baseTotal) || 0;
    const totalAmountNum = parseFloat(totalWithFee) || 0;
    const platformFeeNum = parseFloat(platformFee) || 0;
    const eventTimeNum = eventTime ? parseInt(eventTime) : null;

    const totalQty = ticketQtyNum + tableQtyNum;
    let type = "ticket";
    if (ticketQtyNum > 0 && tableQtyNum > 0) type = "mixed";
    else if (tableQtyNum > 0 && ticketQtyNum === 0) type = "table";

    try {
      const purchaseRef = admin.database().ref(`purchases/${userId}`).push();

      await purchaseRef.set({
        id: purchaseRef.key,
        userId,
        eventId,
        eventTitle: eventName,
        eventImagePath,
        quantity: totalQty,
        type,
        ticketQty: ticketQtyNum,
        ticketPrice: ticketPriceNum,
        tableQty: tableQtyNum,
        tablePrice: tablePriceNum,
        baseAmount: baseAmountNum,
        platformFee: platformFeeNum,
        totalAmount: totalAmountNum,
        payoutMethod,
        payoutDetails,
        paymentMethod,
        timestamp,
        eventTime: eventTimeNum,
      });

      console.log("✅ Logged manual purchase for:", userId, "→", eventName);
      res.status(200).send({ success: true });
    } catch (error) {
      console.error("❌ Failed to log manual purchase:", error);
      res.status(500).send({ error: error.message });
    }
  })
);

// ===================================================
// Nightlife Approvals — callable functions (vetted)
// ===================================================

exports.submitNightlifeApplication = fn.https.onCall(async (data, context) => {
  if (!context.auth)
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  const uid = context.auth.uid;
  const {
    type,
    fullName = "",
    email = "",
    phone = "",
    businessName = "",
    website = null,
    instagram = null,
    tiktok = null,
    description = null,
  } = data || {};

  if (!["promoter", "venue"].includes(type)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "type must be 'promoter' or 'venue'"
    );
  }
  if (!fullName || !email) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "fullName and email are required"
    );
  }

  const node =
    type === "promoter" ? "promoterApplications" : "venueApplications";
  const payload = {
    uid,
    fullName,
    email,
    phone,
    businessName,
    website,
    instagram,
    tiktok,
    description,
    status: "pending",
    submittedAt: Date.now(),
  };
  await db.ref(`${node}/${uid}`).set(payload);
  return { ok: true };
});

exports.listNightlifeApplications = fn.https.onCall(async (data) => {
  const { type, status, limit = 200 } = data || {};
  if (!["promoter", "venue"].includes(type)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "type must be 'promoter' or 'venue'"
    );
  }
  if (!["pending", "approved", "rejected"].includes(status)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "status must be pending|approved|rejected"
    );
  }

  const node =
    type === "promoter" ? "promoterApplications" : "venueApplications";
  const snap = await db
    .ref(node)
    .orderByChild("status")
    .equalTo(status)
    .limitToFirst(limit)
    .get();

  const items = [];
  snap.forEach((child) => {
    const v = child.val() || {};
    items.push({
      uid: child.key,
      fullName: v.fullName || "",
      email: v.email || "",
      phone: v.phone || "",
      businessName: v.businessName || "",
      website: v.website || null,
      instagram: v.instagram || null,
      tiktok: v.tiktok || null,
      description: v.description || null,
      status: v.status || "pending",
      submittedAt: v.submittedAt || null,
    });
  });

  return { items };
});

exports.reviewNightlifeApplication = fn.https.onCall(async (data) => {
  const { type, uid, action, reason = null, venue = null } = data || {};

  if (!["promoter", "venue"].includes(type)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "type must be 'promoter' or 'venue'"
    );
  }
  if (!uid || !["approve", "reject"].includes(action)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "uid and action required"
    );
  }

  const isPromoter = type === "promoter";
  const appNode = isPromoter ? "promoterApplications" : "venueApplications";
  const appRef = db.ref(`${appNode}/${uid}`);
  const appSnap = await appRef.get();
  if (!appSnap.exists())
    throw new functions.https.HttpsError("not-found", "Application not found");

  const updates = {};
  if (action === "reject") {
    updates[`${appNode}/${uid}/status`] = "rejected";
    updates[`${appNode}/${uid}/reviewedAt`] = Date.now();
    if (reason) updates[`${appNode}/${uid}/reason`] = reason;
    await db.ref().update(updates);
    return { ok: true, status: "rejected" };
  }

  // APPROVE
  if (isPromoter) {
    updates[`promoters/${uid}`] = { approved: true, createdAt: Date.now() };
    updates[`${appNode}/${uid}/status`] = "approved";
    updates[`${appNode}/${uid}/reviewedAt`] = Date.now();
    await db.ref().update(updates);
    return { ok: true, status: "approved", type: "promoter" };
  } else {
    const venueId =
      venue && typeof venue.venueId === "string" ? venue.venueId.trim() : "";
    if (!venueId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "venue.venueId is required to approve a venue"
      );
    }

    const venueUpdates = {};
    if (venue.name) venueUpdates[`venues/${venueId}/name`] = venue.name;
    if (venue.address) venueUpdates[`venues/${venueId}/address`] = venue.address;
    venueUpdates[`venues/${venueId}/approved`] = true;
    venueUpdates[`venueAdmins/${venueId}/${uid}`] = true;

    updates[`${appNode}/${uid}/status`] = "approved";
    updates[`${appNode}/${uid}/reviewedAt`] = Date.now();

    await db.ref().update({ ...updates, ...venueUpdates });

    return { ok: true, status: "approved", type: "venue", venueId };
  }
});

// =========================
// 🔥 External feed proxies (direct endpoints; JSON array only)
// =========================

// Polyfill fetch if needed (Node 18 in some environments)
const _nodeFetch = (...args) =>
  import("node-fetch").then(({ default: f }) => f(...args));
const _fetch = globalThis.fetch ? globalThis.fetch.bind(globalThis) : _nodeFetch;

// Feed utils
const FEED = {
  zISO(d) {
    const dt = d instanceof Date ? d : new Date(d);
    return dt.toISOString().replace(/\.\d{3}Z$/, "Z");
  },
  clampWindow(start, end, maxDays = 14) {
    const s = start ? new Date(start) : new Date();
    let e = end ? new Date(end) : new Date(Date.now() + maxDays * 864e5);
    if (e < s) e = new Date(s.getTime() + 864e5);
    if (e.getTime() - s.getTime() > maxDays * 864e5) {
      e = new Date(s.getTime() + maxDays * 864e5);
    }
    return { start: s, end: e };
  },
  joinAddress(parts) {
    return parts.filter(Boolean).join(", ");
  },
  pickHero(images) {
    const list = Array.isArray(images) ? images : [];
    if (!list.length) return null;

    const clean = (u) => {
      if (!u || typeof u !== "string") return null;
      let url = u.startsWith("http:") ? u.replace(/^http:/, "https:") : u;
      const lower = url.toLowerCase();
      if (lower.includes("placeholder") || lower.includes("pixel") || lower.endsWith("/0")) {
        return null;
      }
      return url;
    };

    const r169 = list
      .filter((i) => (i?.ratio || "").includes("16_9") && clean(i?.url))
      .sort(
        (a, b) =>
          (b?.width || 0) * (b?.height || 0) - (a?.width || 0) * (a?.height || 0)
      );

    if (r169.length) return clean(r169[0].url);

    const big = list
      .filter((i) => clean(i?.url))
      .sort(
        (a, b) =>
          (b?.width || 0) * (b?.height || 0) - (a?.width || 0) * (a?.height || 0)
      )[0];

    return clean(big?.url) || null;
  },
  safeNum(n) {
    const x = Number(n);
    return Number.isFinite(x) ? x : null;
  },
  // Force JSON array; add robust headers for iOS/HTTP3
  sendArray(res, arr, status = 200, extraHeaders = {}) {
    const payload = Array.isArray(arr) ? arr : [];
    const buf = Buffer.from(JSON.stringify(payload));
    res.status(status);

    // CORS + transport hardening (avoid HTTP/3/QUIC flakiness)
    res.set({
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "private, max-age=60, no-transform",
      "X-Content-Type-Options": "nosniff",
      "Cross-Origin-Resource-Policy": "cross-origin",
      "Alt-Svc": "clear", // do not upgrade to h3 on iOS
      "Connection": "close",
      "Content-Length": String(buf.length),
      ...extraHeaders,
    });

    res.end(buf);
  },
  withCors(handler) {
    return async (req, res) => {
      try {
        // Preflight
        res.set("Access-Control-Allow-Origin", "*");
        res.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
        res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
        res.set("Alt-Svc", "clear");
        if (req.method === "OPTIONS") return res.status(204).end();
        await handler(req, res);
      } catch (err) {
        console.error("Feed fatal error:", err);
        FEED.sendArray(res, [], 200);
      }
    };
  },
};

// Read config at runtime (avoid init-time throws)
function getTmKey() {
  try {
    return (
      (functions.config().tm && functions.config().tm.key) ||
      process.env.TM_API_KEY ||
      ""
    );
  } catch {
    return process.env.TM_API_KEY || "";
  }
}
function getEbToken() {
  try {
    return (
      (functions.config().eventbrite && functions.config().eventbrite.token) ||
      process.env.EVENTBRITE_TOKEN ||
      ""
    );
  } catch {
    return process.env.EVENTBRITE_TOKEN || "";
  }
}

// Simple ping (always JSON)
exports.ping = fn.https.onRequest(
  FEED.withCors(async (_req, res) =>
    FEED.sendArray(res, [{ ok: true, ts: Date.now() }])
  )
);

// Ticketmaster Discovery feed (direct endpoint)
exports.feedTicketmaster = fn.https.onRequest(
  FEED.withCors(async (req, res) => {
    const TM_KEY = getTmKey();
    const debug = req.query?.debug === "1";
    let _debug = [];

    if (!TM_KEY) {
      console.warn("TM_API_KEY missing → returning empty array");
      return FEED.sendArray(res, debug ? [{ _debug: [{ error: "TM key missing" }] }] : []);
    }

    const city = (req.query.city || "").toString().trim();
    const startRaw = (req.query.start || "").toString().trim();
    const endRaw = (req.query.end || "").toString().trim();
    const { start, end } = FEED.clampWindow(startRaw, endRaw);

    const u = new URL("https://app.ticketmaster.com/discovery/v2/events.json");
    u.searchParams.set("apikey", TM_KEY);
    u.searchParams.set("size", "50");
    u.searchParams.set("sort", "date,asc");
    u.searchParams.set("countryCode", "US");
    u.searchParams.set("classificationName", "Music");
    if (city) u.searchParams.set("city", city);
    u.searchParams.set("startDateTime", FEED.zISO(start));
    u.searchParams.set("endDateTime", FEED.zISO(end));

    let items = [];
    try {
      const resp = await _fetch(u.toString(), { method: "GET" });
      if (!resp.ok) {
        const t = await resp.text().catch(() => "");
        console.warn("TM non-200:", resp.status, t.slice(0, 200));
        if (debug) _debug.push({ status: resp.status, body: t.slice(0, 400) });
        return FEED.sendArray(res, debug ? [{ _debug }, ...[]] : []);
      }
      const data = await resp.json().catch((e) => {
        if (debug) _debug.push({ parseError: String(e) });
        return null;
      });
      const list = data?._embedded?.events ?? [];

      items = list.map((ev) => {
        const venue = ev?._embedded?.venues?.[0] || {};
        const hero =
          FEED.pickHero(ev?.images) ||
          FEED.pickHero(ev?._embedded?.attractions?.[0]?.images) ||
          (ev?.seatmap?.staticUrl || null);

        const when =
          ev?.dates?.start?.dateTime ||
          (ev?.dates?.start?.localDate
            ? `${ev.dates.start.localDate}T${ev.dates.start.localTime || "00:00:00"}Z`
            : new Date());

        return {
          id: String(ev?.id || ev?.url || ev?.name || Math.random()),
          title: String(ev?.name || "Event"),
          venueName: String(venue?.name || ""),
          address: FEED.joinAddress([
            venue?.address?.line1,
            venue?.city?.name,
            venue?.state?.stateCode || venue?.state?.name,
            venue?.country?.countryCode,
          ]),
          date: FEED.zISO(when),
          price: FEED.safeNum(ev?.priceRanges?.[0]?.min),
          externalURL: typeof ev?.url === "string" ? ev.url : null,
          source: "ticketmaster",
          heroImage: hero || null,
        };
      });
    } catch (e) {
      console.error("TM fetch/parse error:", e);
      if (debug) _debug.push({ error: String(e) });
    }

    const requireImage = (req.query?.requireImage ?? "0") === "1";
    if (requireImage) items = items.filter((x) => !!x.heroImage);

    const imagesFirst = (req.query?.imagesFirst ?? "1") !== "0";
    if (imagesFirst) {
      items.sort((a, b) => {
        const ai = a.heroImage ? 1 : 0;
        const bi = b.heroImage ? 1 : 0;
        if (ai !== bi) return bi - ai;
        return new Date(a.date) - new Date(b.date);
      });
    } else {
      items.sort((a, b) => new Date(a.date) - new Date(b.date));
    }

    return FEED.sendArray(res, debug ? [{ _debug }, ...items] : items);
  })
);

// Eventbrite Search feed (direct endpoint)
exports.feedEventbrite = fn.https.onRequest(
  FEED.withCors(async (req, res) => {
    const EB_TOKEN = getEbToken();
    const debug = req.query?.debug === "1";
    let _debug = [];

    if (!EB_TOKEN) {
      console.warn("EVENTBRITE_TOKEN missing → returning empty array");
      return FEED.sendArray(
        res,
        debug ? [{ _debug: [{ error: "Eventbrite token missing" }] }] : []
      );
    }

    const city = (req.query.city || "").toString().trim();
    const startRaw = (req.query.start || "").toString().trim();
    const endRaw = (req.query.end || "").toString().trim();
    const { start, end } = FEED.clampWindow(startRaw, endRaw);

    const u = new URL("https://www.eventbriteapi.com/v3/events/search/");
    u.searchParams.set("sort_by", "date");
    u.searchParams.set("expand", "venue,logo,organizer");
    u.searchParams.set("page_size", "50");
    u.searchParams.set("start_date.range_start", FEED.zISO(start));
    u.searchParams.set("start_date.range_end", FEED.zISO(end));
    if (city) u.searchParams.set("location.address", city);

    let items = [];
    try {
      const resp = await _fetch(u.toString(), {
        method: "GET",
        headers: { Authorization: `Bearer ${EB_TOKEN}` },
      });
      if (!resp.ok) {
        const t = await resp.text().catch(() => "");
        console.warn("EB non-200:", resp.status, t.slice(0, 200));
        if (debug) _debug.push({ status: resp.status, body: t.slice(0, 400) });
        return FEED.sendArray(res, debug ? [{ _debug }, ...[]] : []);
      }
      const data = await resp.json().catch((e) => {
        if (debug) _debug.push({ parseError: String(e) });
        return null;
      });
      const list = Array.isArray(data?.events) ? data.events : [];

      items = list.map((ev) => {
        const v = ev?.venue || {};
        const when = ev?.start?.utc || ev?.start?.local || new Date();
        const address =
          v?.address?.localized_address_display ||
          v?.localized_address_display ||
          FEED.joinAddress([v?.name]);

        const hero =
          ev?.logo?.url ||
          ev?.logo?.original?.url ||
          ev?.logo?.crop_mask?.url ||
          ev?.organizer?.logo?.url ||
          null;

        return {
          id: String(ev?.id || ev?.url || ev?.name?.text || Math.random()),
          title: String(ev?.name?.text || ev?.name || ev?.summary || "Event"),
          venueName: String(v?.name || ""),
          address,
          date: FEED.zISO(when),
          price: null,
          externalURL: typeof ev?.url === "string" ? ev.url : null,
          source: "eventbrite",
          heroImage: hero,
        };
      });
    } catch (e) {
      console.error("EB fetch/parse error:", e);
      if (debug) _debug.push({ error: String(e) });
    }

    const requireImage = (req.query?.requireImage ?? "0") === "1";
    if (requireImage) items = items.filter((x) => !!x.heroImage);

    const imagesFirst = (req.query?.imagesFirst ?? "1") !== "0";
    if (imagesFirst) {
      items.sort((a, b) => {
        const ai = a.heroImage ? 1 : 0;
        const bi = b.heroImage ? 1 : 0;
        if (ai !== bi) return bi - ai;
        return new Date(a.date) - new Date(b.date);
      });
    } else {
      items.sort((a, b) => new Date(a.date) - new Date(b.date));
    }

    return FEED.sendArray(res, debug ? [{ _debug }, ...items] : items);
  })
);

// =========================
/* Optional dynamic modules (unchanged) */
// =========================
try {
  const nightlife = require("./nightlife")(fn, admin);
  Object.assign(exports, nightlife);
} catch (e) {
  console.log("ℹ️ nightlife module not present, skipping");
}

try {
  const extraFeeds = require("./externalFeeds")(fn, admin);
  for (const [k, v] of Object.entries(extraFeeds || {})) {
    if (exports[k]) {
      console.warn(`⚠️ Skipping duplicate export '${k}' from externalFeeds`);
    } else {
      exports[k] = v;
    }
  }
} catch (e) {
  console.log("ℹ️ externalFeeds module not present, skipping");
}
