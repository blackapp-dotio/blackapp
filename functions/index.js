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

/// ===================================================
// Nightlife Approvals — callable functions (v3)
// Supports promoter, venue, entertainer
// Actions: approve | reject | suspend | reinstate
// ===================================================

// submitNightlifeApplication
exports.submitNightlifeApplication = fn.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }
  const uid = context.auth.uid;

  const {
    type,
    fullName = "",
    email = "",
    phone = "",
    businessName = "",
    stageName = "",           // used for entertainer
    website = null,
    instagram = null,
    tiktok = null,
    description = null,
  } = data || {};

  if (!["promoter", "venue", "entertainer"].includes(type)) {
    throw new functions.https.HttpsError("invalid-argument", "type must be 'promoter' | 'venue' | 'entertainer'");
  }
  if (!fullName || !email) {
    throw new functions.https.HttpsError("invalid-argument", "fullName and email are required");
  }

  const node =
    type === "promoter" ? "promoterApplications" :
    type === "venue"    ? "venueApplications"    :
                          "entertainerApplications";

  const payload = {
    uid,
    type,
    fullName,
    email,
    phone,
    businessName,
    ...(type === "entertainer" ? { stageName } : {}),
    website,
    instagram,
    tiktok,
    description,
    status: "pending",
    approved: false,
    suspended: false,
    submittedAt: admin.database.ServerValue.TIMESTAMP,
  };

  await db.ref(`${node}/${uid}`).set(payload);
  return { ok: true };
});

// listNightlifeApplications
exports.listNightlifeApplications = fn.https.onCall(async (data) => {
  const { type, status = "pending", limit = 200 } = data || {};
  if (!["promoter", "venue", "entertainer"].includes(type)) {
    throw new functions.https.HttpsError("invalid-argument", "type must be 'promoter' | 'venue' | 'entertainer'");
  }
  if (!["pending", "approved", "rejected"].includes(status)) {
    throw new functions.https.HttpsError("invalid-argument", "status must be 'pending' | 'approved' | 'rejected'");
  }

  const node =
    type === "promoter" ? "promoterApplications" :
    type === "venue"    ? "venueApplications"    :
                          "entertainerApplications";

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
      type: v.type || type,
      fullName: v.fullName || "",
      email: v.email || "",
      phone: v.phone || "",
      businessName: v.businessName || "",
      website: v.website ?? null,
      instagram: v.instagram ?? null,
      tiktok: v.tiktok ?? null,
      description: v.description ?? null,
      status: v.status || "pending",
      suspended: !!v.suspended,   // included for UIs (approved list can show suspended)
      submittedAt: v.submittedAt || null,
    });
  });

  return { items };
});
// APPROVE / REJECT / SUSPEND / REINSTATE (promoter | venue | entertainer)
// v1 callable, pinned to us-central1
exports.reviewNightlifeApplication = fn.https.onCall(async (data, context) => {
  const { HttpsError } = functions.https;

  try {
    // ---- auth ----
    if (!context.auth) {
      throw new HttpsError("unauthenticated", "Login required");
    }
    const adminUid = context.auth.uid || null;

    // ---- args ----
    const { type, uid, action, reason = null, venue = null } = data || {};
    const ALLOWED_TYPES = new Set(["promoter", "venue", "entertainer"]);
    const ALLOWED_ACTIONS = new Set(["approve", "reject", "suspend", "reinstate"]);

    if (!ALLOWED_TYPES.has(type)) {
      throw new HttpsError(
        "invalid-argument",
        "type must be 'promoter' | 'venue' | 'entertainer'"
      );
    }
    if (!uid || !ALLOWED_ACTIONS.has(action)) {
      throw new HttpsError("invalid-argument", "uid and valid action required");
    }

    const appNode =
      type === "promoter" ? "promoterApplications" :
      type === "venue"    ? "venueApplications"    :
                            "entertainerApplications";

    const appRef = db.ref(`${appNode}/${uid}`);
    const appSnap = await appRef.get();
    if (!appSnap.exists()) {
      throw new HttpsError("not-found", "Application not found");
    }
    const app = appSnap.val() || {};
    const now = admin.database.ServerValue.TIMESTAMP;

    // helpers
    const updates = {};
    const set = (path, val) => { updates[path] = val; };
    const markReviewed = () => {
      set(`${appNode}/${uid}/reviewedAt`, now);
      if (adminUid) set(`${appNode}/${uid}/reviewedBy`, adminUid);
    };

    // ---------- REJECT ----------
    if (action === "reject") {
      set(`${appNode}/${uid}/status`, "rejected");
      set(`${appNode}/${uid}/approved`, false);
      set(`${appNode}/${uid}/suspended`, false);
      if (reason) set(`${appNode}/${uid}/reason`, String(reason));
      markReviewed();
      await db.ref().update(updates);
      return { ok: true, action, status: "rejected", type };
    }

    // ---------- SUSPEND / REINSTATE ----------
    if (action === "suspend" || action === "reinstate") {
      const suspended = action === "suspend";

      // mirror to application
      set(`${appNode}/${uid}/suspended`, suspended);
      set(`${appNode}/${uid}/moderatedAt`, now);
      if (adminUid) set(`${appNode}/${uid}/moderatedBy`, adminUid);

      // mirror to role node(s)
      if (type === "promoter") {
        set(`promoters/${uid}/suspended`, suspended);
        set(`promoters/${uid}/moderatedAt`, now);
        if (adminUid) set(`promoters/${uid}/moderatedBy`, adminUid);
      } else if (type === "entertainer") {
        set(`entertainers/${uid}/suspended`, suspended);
        set(`entertainers/${uid}/moderatedAt`, now);
        if (adminUid) set(`entertainers/${uid}/moderatedBy`, adminUid);
      } else {
        // venue: use owner index to find venueId (safe if missing)
        const ownerSnap = await db.ref(`venueOwners/${uid}`).get();
        const owner = ownerSnap.exists() ? ownerSnap.val() || {} : {};
        const venueId = owner.venueId || null;

        set(`venueOwners/${uid}/suspended`, suspended);
        set(`venueOwners/${uid}/moderatedAt`, now);
        if (adminUid) set(`venueOwners/${uid}/moderatedBy`, adminUid);

        if (venueId) {
          set(`venues/${venueId}/suspended`, suspended);
          set(`venues/${venueId}/moderatedAt`, now);
          if (adminUid) set(`venues/${venueId}/moderatedBy`, adminUid);
        }
      }

      await db.ref().update(updates);
      return { ok: true, action, suspended, type };
    }

    // ---------- APPROVE ----------
    set(`${appNode}/${uid}/status`, "approved");
    set(`${appNode}/${uid}/approved`, true);
    set(`${appNode}/${uid}/suspended`, false);
    markReviewed();

    if (type === "promoter") {
      set(`promoters/${uid}/approved`, true);
      set(`promoters/${uid}/suspended`, false);
      set(`promoters/${uid}/createdAt`, now);
      await db.ref().update(updates);
      return { ok: true, action: "approve", status: "approved", type };
    }

    // ---------- APPROVE ----------
set(`${appNode}/${uid}/status`, "approved");
set(`${appNode}/${uid}/approved`, true);
set(`${appNode}/${uid}/suspended`, false);
markReviewed();
set(`${appNode}/${uid}/approvedAt`, now); // <-- add approvedAt like venue/promoter

if (type === "entertainer") {
  const stageName =
    (app.stageName && String(app.stageName).trim()) ||
    (app.businessName && String(app.businessName).trim()) || "";

  // Create/overwrite entertainers/{uid} to match your other role nodes
  set(`entertainers/${uid}/approved`, true);
  set(`entertainers/${uid}/approvedAt`, now);
  set(`entertainers/${uid}/suspended`, false);
  set(`entertainers/${uid}/createdAt`, now);

  // Keep parity with what you store for venues/promoters
  set(`entertainers/${uid}/uid`, uid);
  set(`entertainers/${uid}/sourceApplication`, "entertainerApplications");

  // Copy key profile fields so the portal can render without chasing the app node
  if (app.fullName)      set(`entertainers/${uid}/fullName`, app.fullName);
  if (stageName)         set(`entertainers/${uid}/stageName`, stageName);
  if (app.businessName)  set(`entertainers/${uid}/businessName`, app.businessName);
  if (app.email)         set(`entertainers/${uid}/email`, app.email);
  if (app.phone)         set(`entertainers/${uid}/phone`, app.phone);
  if (app.instagram)     set(`entertainers/${uid}/instagram`, app.instagram);
  if (app.tiktok)        set(`entertainers/${uid}/tiktok`, app.tiktok);
  if (app.website)       set(`entertainers/${uid}/website`, app.website);
  if (app.description)   set(`entertainers/${uid}/description`, app.description);

  await db.ref().update(updates);
  return { ok: true, action: "approve", status: "approved", type };
}


    // venue approval
    let venueId =
      venue && typeof venue.venueId === "string" && venue.venueId.trim()
        ? venue.venueId.trim()
        : "";

    if (!venueId) {
      const newRef = db.ref("venues").push();
      venueId = newRef.key;
      await newRef.set({
        name: (venue && venue.name) || app.businessName || "",
        address: (venue && venue.address) || "",
        approved: true,
        suspended: false,
        createdAt: now,
      });
    } else {
      const vUpdates = { approved: true, suspended: false };
      if (venue?.name && venue.name.trim()) vUpdates.name = venue.name.trim();
      if (venue?.address && venue.address.trim()) vUpdates.address = venue.address.trim();
      await db.ref(`venues/${venueId}`).update(vUpdates);
    }

    set(`venueAdmins/${venueId}/${uid}`, true);
    set(`venueOwners/${uid}/venueId`, venueId);
    set(`venueOwners/${uid}/approved`, true);
    set(`venueOwners/${uid}/suspended`, false);
    set(`venueOwners/${uid}/linkedAt`, now);
    set(`${appNode}/${uid}/venueId`, venueId);

    await db.ref().update(updates);
    return { ok: true, action: "approve", status: "approved", type, venueId };
  } catch (e) {
    console.error("reviewNightlifeApplication error:", e);

    // If it was already an HttpsError (e.g., invalid-argument), keep it.
    if (e instanceof functions.https.HttpsError) throw e;

    // Otherwise surface real info to the client (iOS will log this under FunctionsErrorDetailsKey).
    throw new functions.https.HttpsError(
      "internal",
      "reviewNightlifeApplication failed",
      { message: e?.message || String(e), stack: e?.stack, name: e?.name }
    );
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

//--------------
//ACCEPTINVITES
//--------------


/**
 * acceptInvite (Callable, v1)
 * data: { inviterId: string, inviteeId: string }
 * auth: required; inviterId must equal context.auth.uid
 */
exports.acceptInvite = functions.https.onCall(async (data, context) => {
  const auth = context.auth;
  const inviterId = data && data.inviterId;
  const inviteeId = data && data.inviteeId;

  // ---- Validation ----
  if (!auth || !auth.uid) {
    throw new functions.https.HttpsError('unauthenticated', 'You must be signed in to accept an invite.');
  }
  if (!inviterId || !inviteeId) {
    throw new functions.https.HttpsError('invalid-argument', 'inviterId and inviteeId are required.');
  }
  if (inviterId !== auth.uid) {
    throw new functions.https.HttpsError('permission-denied', 'inviterId must match the authenticated user.');
  }
  if (inviterId === inviteeId) {
    throw new functions.https.HttpsError('failed-precondition', 'Self-invites are not allowed.');
  }

  const acceptRef = db.ref(`invitesAccepted/${inviteeId}`);

  // ---- Step 1: Idempotent accept via transaction ----
  const acceptTxn = await acceptRef.transaction((current) => {
    if (current) return; // already accepted -> abort write
    return {
      inviterId,
      inviteeId,
      timestamp: Date.now(),
      status: 'accepted',
    };
  }, { applyLocally: false });

  if (!acceptTxn.committed) {
    // Another process already accepted — return current state
    const [circleSize, badgeTier] = await Promise.all([
      getCircleSize(inviterId),
      getBadgeTier(inviterId),
    ]);
    return {
      status: 'already_accepted',
      circleSize,
      badgeTier,
      payload: acceptTxn.snapshot.val(),
    };
  }

  // ---- Step 2: Increment inviter's circleSize atomically ----
  const circleRef = db.ref(`users/${inviterId}/circleSize`);
  const circleTxn = await circleRef.transaction(
    (val) => (typeof val === 'number' ? val + 1 : 1),
    { applyLocally: false }
  );
  const circleSize = circleTxn.snapshot.val() || 1;

  // ---- Step 3: Compute badge tier (white baseline, then rainbow → black) ----
  const tiers = [
    { name: 'white',  threshold: 0 },
    { name: 'red',    threshold: 5 },
    { name: 'orange', threshold: 10 },
    { name: 'yellow', threshold: 20 },
    { name: 'green',  threshold: 40 },
    { name: 'blue',   threshold: 80 },
    { name: 'indigo', threshold: 160 },
    { name: 'violet', threshold: 320 },
    { name: 'black',  threshold: 640 },
  ];
  let badge = 'white';
  for (let i = tiers.length - 1; i >= 0; i--) {
    if (circleSize >= tiers[i].threshold) { badge = tiers[i].name; break; }
  }

  // ---- Step 4: Contacts (both directions) + badge (multi-path update) ----
  const updates = {};
  updates[`users/${inviterId}/badgeTier`] = badge;
  updates[`contacts/${inviterId}/${inviteeId}`] = true;
  updates[`contacts/${inviteeId}/${inviterId}`] = true;

  await db.ref().update(updates);

  return {
    status: 'accepted',
    circleSize,
    badgeTier: badge,
  };
});

// ------- Helpers (v1) -------
async function getCircleSize(uid) {
  const snap = await db.ref(`users/${uid}/circleSize`).get();
  return snap.exists() ? snap.val() : 0;
}
async function getBadgeTier(uid) {
  const snap = await db.ref(`users/${uid}/badgeTier`).get();
  return snap.exists() ? snap.val() : 'white';
}

/**
 * OPTIONAL: seed defaults on-demand if your signup flow doesn’t do it.
 * Call from client once after sign-in.
 */
 exports.ensureUserDefaults = functions.https.onCall(async (_, context) => {
   if (!context.auth || !context.auth.uid) {
     throw new functions.https.HttpsError('unauthenticated', 'Sign in required.');
   }
   const uid = context.auth.uid;
   const ref = db.ref(`users/${uid}`);
   const snap = await ref.get();
   if (!snap.exists()) {
     await ref.set({ circleSize: 0, badgeTier: 'white' });
     return { created: true, circleSize: 0, badgeTier: 'white' };
   }
   const val = snap.val() || {};
   const updates = {};
   if (typeof val.circleSize !== 'number') updates.circleSize = 0;
   if (typeof val.badgeTier !== 'string') updates.badgeTier = 'white';
   if (Object.keys(updates).length) await ref.update(updates);
   return { created: false, ...val, ...updates };
 });


const serverTimestamp = admin.firestore.FieldValue.serverTimestamp;

const REGION = 'us-central1'; // change if you deploy elsewhere

// ---------- helpers ----------
const chatId = (a, b) => [a, b].sort().join('_');

// human-friendly short codes: BA-7GQ4N9 (no 0/1/O/I)
const CODE_PREFIX = 'BA-';
const CODE_CHARS = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

function makeCode(len = 7) {
  let s = CODE_PREFIX;
  for (let i = 0; i < len; i++) {
    s += CODE_CHARS[Math.floor(Math.random() * CODE_CHARS.length)];
  }
  return s;
}

async function generateUniqueCode() {
  for (let i = 0; i < 8; i++) {
    const code = makeCode();
    const ref = db.collection('inviteCodes').doc(code);
    const snap = await ref.get();
    if (!snap.exists) return code;
  }
  throw new Error('Could not generate unique invite code after several attempts');
}

async function ensureMutualContacts(aUid, bUid, status, source) {
  const aRef = db.collection('users').doc(aUid).collection('contacts').doc(bUid);
  const bRef = db.collection('users').doc(bUid).collection('contacts').doc(aUid);
  const dcRef = db.collection('directChats').doc(chatId(aUid, bUid));

  const [aSnap, bSnap, dcSnap] = await Promise.all([aRef.get(), bRef.get(), dcRef.get()]);
  const active = status === 'active';

  const batch = db.batch();

  const up = (ref, cur) => {
    const curStatus = cur?.status;
    const curAccepted = !!cur?.accepted;
    const needs = curStatus !== status || curAccepted !== active;
    if (needs) {
      batch.set(
        ref,
        {
          status,
          accepted: active,
          source,
          createdAt: cur?.createdAt || serverTimestamp(),
        },
        { merge: true }
      );
    }
  };

  up(aRef, aSnap.data());
  up(bRef, bSnap.data());

  if (!dcSnap.exists) {
    batch.set(dcRef, {
      participants: [aUid, bUid],
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      pending: !active,
      userA: aUid,
      userB: bUid,
    });
  } else if (active && dcSnap.get('pending') === true) {
    batch.update(dcRef, { pending: false, updatedAt: serverTimestamp() });
  }

  await batch.commit();
}

// ---------- TRIGGERS ----------

// 1) Assign short invite code to NEW users (if missing)
exports.onUserCreated = functions
  .region(REGION)
  .firestore.document('users/{uid}')
  .onCreate(async (snap, ctx) => {
    const uid = ctx.params.uid;
    const data = snap.data() || {};
    if (data.inviteCode) return; // already has one (idempotent)

    const code = await generateUniqueCode();
    await Promise.all([
      snap.ref.set({ inviteCode: code }, { merge: true }),
      db.collection('inviteCodes').doc(code).set({
        uid,
        createdAt: serverTimestamp(),
      }),
    ]);
  });

// 2) When user doc gets a `referrer`, link both sides + active DM (once)
exports.onUserReferrerSet = functions
  .region(REGION)
  .firestore.document('users/{uid}')
  .onWrite(async (change, ctx) => {
    if (!change.after.exists) return;

    const uid = ctx.params.uid;
    const before = change.before.data() || {};
    const after = change.after.data() || {};

    const prevRef = before.referrer;
    const referrer = after.referrer;
    const processed = after.referralProcessed === true;

    if (!referrer || processed) return;
    if (referrer === uid) return; // ignore self
    if (prevRef === referrer) return; // no change

    await ensureMutualContacts(referrer, uid, 'active', 'invite');

    await change.after.ref.set({ referralProcessed: true }, { merge: true });
  });

// 3) If either side activates a pending contact, mirror & clear chat.pending
exports.onContactActivated = functions
  .region(REGION)
  .firestore.document('users/{uid}/contacts/{otherUid}')
  .onUpdate(async (change, ctx) => {
    const uid = ctx.params.uid;
    const other = ctx.params.otherUid;

    const before = change.before.data() || {};
    const after = change.after.data() || {};

    const wasActive = before.status === 'active' && before.accepted === true;
    const isActive = after.status === 'active' && after.accepted === true;
    if (!isActive || wasActive) return;

    const mirrorRef = db.collection('users').doc(other).collection('contacts').doc(uid);
    const dcRef = db.collection('directChats').doc(chatId(uid, other));

    const [mirrorSnap, dcSnap] = await Promise.all([mirrorRef.get(), dcRef.get()]);

    const batch = db.batch();

    const mirrorIsActive =
      mirrorSnap.exists &&
      mirrorSnap.get('status') === 'active' &&
      mirrorSnap.get('accepted') === true;

    if (!mirrorIsActive) {
      batch.set(
        mirrorRef,
        {
          status: 'active',
          accepted: true,
          source: after.source || 'search',
          createdAt: mirrorSnap.get?.('createdAt') || serverTimestamp(),
        },
        { merge: true }
      );
    }

    if (dcSnap.exists && dcSnap.get('pending') === true) {
      batch.update(dcRef, { pending: false, updatedAt: serverTimestamp() });
    }

    await batch.commit();
  });

// ---------- ONE-TIME BACKFILL ENDPOINT ----------
// Assign inviteCode to existing users (and ensure mapping), paginated.
// Protect with an admin key: `firebase functions:config:set backfill.key="YOUR_SECRET"`
exports.backfillInviteCodes = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== 'POST') {
        res.status(405).send('Use POST');
        return;
      }

      const configured = (functions.config()?.backfill?.key) || '';
      const provided = req.header('x-admin-key') || '';
      if (!configured || provided !== configured) {
        res.status(403).send('forbidden');
        return;
      }

      // pagination
      const limit = Math.min(parseInt(String(req.query.limit || '200'), 10), 500);
      const after = req.query.after ? String(req.query.after) : undefined;

      let q = db.collection('users').orderBy(admin.firestore.FieldPath.documentId()).limit(limit);
      if (after) q = q.startAfter(after);

      const snap = await q.get();
      if (snap.empty) {
        res.json({ processed: 0, assigned: 0, fixedMappings: 0, nextAfter: null });
        return;
      }

      let processed = 0;
      let assigned = 0;
      let fixedMappings = 0;

      const batch = db.batch();

      for (const doc of snap.docs) {
        processed++;
        const uid = doc.id;
        const data = doc.data() || {};
        const existingCode = data.inviteCode;

        if (!existingCode) {
          const code = await generateUniqueCode();
          batch.set(doc.ref, { inviteCode: code }, { merge: true });
          batch.set(db.collection('inviteCodes').doc(code), { uid, createdAt: serverTimestamp() });
          assigned++;
        } else {
          const mapRef = db.collection('inviteCodes').doc(existingCode);
          const mapSnap = await mapRef.get();
          if (!mapSnap.exists) {
            batch.set(mapRef, { uid, createdAt: serverTimestamp() }, { merge: true });
            fixedMappings++;
          }
        }
      }

      await batch.commit();

      const nextAfter = snap.docs[snap.docs.length - 1]?.id || null;
      res.json({ processed, assigned, fixedMappings, nextAfter });
    } catch (e) {
      console.error('backfillInviteCodes error:', e);
      res.status(500).send(e?.message || 'error');
    }
  });

// ===== Backfill invite codes for existing users (safe to append) =====
/*  Usage (after setting config key and deploying):
      ADMIN_KEY="YOUR_SUPER_SECRET"
      BASE="https://us-central1-<PROJECT_ID>.cloudfunctions.net/backfillInviteCodes"
      curl -sS -X POST "$BASE?limit=300" -H "x-admin-key: $ADMIN_KEY"
*/

// If these paths differ in your project, adjust:
var USERS_COLL = 'users';
var INVITE_CODES_COLL = 'inviteCodes';

// Local Firestore handle so we don't clash with any existing RTDB `db` var
function _fs() { return require('firebase-admin').firestore(); }

// Short code helpers
var _CODE_PREFIX = 'BA-';
var _CODE_CHARS = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; // no 0,1,O,I

function _makeCode(len) {
  len = len || 7;
  var s = _CODE_PREFIX;
  for (var i = 0; i < len; i++) {
    s += _CODE_CHARS[Math.floor(Math.random() * _CODE_CHARS.length)];
  }
  return s;
}

async function _generateUniqueCode() {
  var fs = _fs();
  for (var i = 0; i < 8; i++) {
    var code = _makeCode();
    var ref = fs.collection(INVITE_CODES_COLL).doc(code);
    var snap = await ref.get();
    if (!snap.exists) return code;
  }
  throw new Error('Could not generate unique invite code');
}

exports.backfillInviteCodes = require('firebase-functions')
  .region('us-central1') // <- change if your other functions use a different region
  .https.onRequest(async function(req, res) {
    try {
      if (req.method !== 'POST') {
        res.status(405).send('Use POST'); return;
      }

      // Read protected admin key from functions config (v1-safe)
      var cfg = require('firebase-functions').config();
      var configured = (cfg && cfg.backfill && cfg.backfill.key) ? cfg.backfill.key : '';
      var provided = req.header('x-admin-key') || '';
      if (!configured || provided !== configured) {
        res.status(403).send('forbidden'); return;
      }

      // Pagination
      var limitRaw = String(req.query.limit || '200');
      var limit = parseInt(limitRaw, 10);
      if (!limit || limit < 1) limit = 200;
      if (limit > 500) limit = 500;

      var after = req.query.after ? String(req.query.after) : null;

      var fs = _fs();
      var q = fs.collection(USERS_COLL)
                .orderBy(require('firebase-admin').firestore.FieldPath.documentId())
                .limit(limit);
      if (after) q = q.startAfter(after);

      var snap = await q.get();
      if (snap.empty) {
        res.json({ processed: 0, assigned: 0, fixedMappings: 0, nextAfter: null }); return;
      }

      var processed = 0, assigned = 0, fixedMappings = 0;
      var batch = fs.batch();
      var ts = require('firebase-admin').firestore.FieldValue.serverTimestamp();

      for (var i = 0; i < snap.docs.length; i++) {
        var doc = snap.docs[i];
        processed++;
        var uid = doc.id;
        var data = doc.data() || {};
        var existingCode = data.inviteCode;

        if (!existingCode) {
          var code = await _generateUniqueCode();
          batch.set(doc.ref, { inviteCode: code }, { merge: true });
          batch.set(fs.collection(INVITE_CODES_COLL).doc(code), { uid: uid, createdAt: ts }, { merge: true });
          assigned++;
        } else {
          var mapRef = fs.collection(INVITE_CODES_COLL).doc(existingCode);
          var mapSnap = await mapRef.get();
          if (!mapSnap.exists) {
            batch.set(mapRef, { uid: uid, createdAt: ts }, { merge: true });
            fixedMappings++;
          }
        }
      }

      await batch.commit();
      var nextAfter = snap.docs[snap.docs.length - 1] ? snap.docs[snap.docs.length - 1].id : null;
      res.json({ processed: processed, assigned: assigned, fixedMappings: fixedMappings, nextAfter: nextAfter });
    } catch (e) {
      console.error('backfillInviteCodes error:', e);
      res.status(500).send(e && e.message ? e.message : 'error');
    }
  });

