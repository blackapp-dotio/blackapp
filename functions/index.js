// functions/index.js
/* eslint-disable no-console */
const admin = require("firebase-admin");
const braintree = require("braintree");
const corsMw = require("cors")({ origin: true });
const functions = require("firebase-functions/v1"); // v1 API (region helper below)

// ---------- NEW (for Gossip feed) ----------
const RSSParser = require("rss-parser");
const sharp = require("sharp");
const { fetch: undiciFetch } = require("undici"); // used by imgThumb
// -------------------------------------------

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
const rtdb = admin.database();
const firestore = admin.firestore();

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

  await rtdb.ref(`${node}/${uid}`).set(payload);
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

  const snap = await rtdb
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
exports.reviewNightlifeApplication = fn.https.onCall(async (data, context) => {
  const { HttpsError } = functions.https;

  try {
    if (!context.auth) {
      throw new HttpsError("unauthenticated", "Login required");
    }
    const adminUid = context.auth.uid || null;

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

    const appRef = rtdb.ref(`${appNode}/${uid}`);
    const appSnap = await appRef.get();
    if (!appSnap.exists()) {
      throw new HttpsError("not-found", "Application not found");
    }
    const app = appSnap.val() || {};
    const now = admin.database.ServerValue.TIMESTAMP;

    const updates = {};
    const set = (path, val) => { updates[path] = val; };
    const markReviewed = () => {
      set(`${appNode}/${uid}/reviewedAt`, now);
      if (adminUid) set(`${appNode}/${uid}/reviewedBy`, adminUid);
    };

    if (action === "reject") {
      set(`${appNode}/${uid}/status`, "rejected");
      set(`${appNode}/${uid}/approved`, false);
      set(`${appNode}/${uid}/suspended`, false);
      if (reason) set(`${appNode}/${uid}/reason`, String(reason));
      markReviewed();
      await rtdb.ref().update(updates);
      return { ok: true, action, status: "rejected", type };
    }

    if (action === "suspend" || action === "reinstate") {
      const suspended = action === "suspend";

      set(`${appNode}/${uid}/suspended`, suspended);
      set(`${appNode}/${uid}/moderatedAt`, now);
      if (adminUid) set(`${appNode}/${uid}/moderatedBy`, adminUid);

      if (type === "promoter") {
        set(`promoters/${uid}/suspended`, suspended);
        set(`promoters/${uid}/moderatedAt`, now);
        if (adminUid) set(`promoters/${uid}/moderatedBy`, adminUid);
      } else if (type === "entertainer") {
        set(`entertainers/${uid}/suspended`, suspended);
        set(`entertainers/${uid}/moderatedAt`, now);
        if (adminUid) set(`entertainers/${uid}/moderatedBy`, adminUid);
      } else {
        const ownerSnap = await rtdb.ref(`venueOwners/${uid}`).get();
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

      await rtdb.ref().update(updates);
      return { ok: true, action, suspended, type };
    }

    // ---------- APPROVE (promoter / entertainer / venue) ----------
    set(`${appNode}/${uid}/status`, "approved");
    set(`${appNode}/${uid}/approved`, true);
    set(`${appNode}/${uid}/suspended`, false);
    set(`${appNode}/${uid}/approvedAt`, now);
    markReviewed();

    if (type === "promoter") {
      set(`promoters/${uid}/approved`, true);
      set(`promoters/${uid}/suspended`, false);
      set(`promoters/${uid}/createdAt`, now);
      await rtdb.ref().update(updates);
      return { ok: true, action: "approve", status: "approved", type };
    }

    if (type === "entertainer") {
      const stageName =
        (app.stageName && String(app.stageName).trim()) ||
        (app.businessName && String(app.businessName).trim()) || "";

      set(`entertainers/${uid}/approved`, true);
      set(`entertainers/${uid}/approvedAt`, now);
      set(`entertainers/${uid}/suspended`, false);
      set(`entertainers/${uid}/createdAt`, now);

      set(`entertainers/${uid}/uid`, uid);
      set(`entertainers/${uid}/sourceApplication`, "entertainerApplications");

      if (app.fullName)      set(`entertainers/${uid}/fullName`, app.fullName);
      if (stageName)         set(`entertainers/${uid}/stageName`, stageName);
      if (app.businessName)  set(`entertainers/${uid}/businessName`, app.businessName);
      if (app.email)         set(`entertainers/${uid}/email`, app.email);
      if (app.phone)         set(`entertainers/${uid}/phone`, app.phone);
      if (app.instagram)     set(`entertainers/${uid}/instagram`, app.instagram);
      if (app.tiktok)        set(`entertainers/${uid}/tiktok`, app.tiktok);
      if (app.website)       set(`entertainers/${uid}/website`, app.website);
      if (app.description)   set(`entertainers/${uid}/description`, app.description);

      await rtdb.ref().update(updates);
      return { ok: true, action: "approve", status: "approved", type };
    }

    // venue approval
    let venueId =
      venue && typeof venue.venueId === "string" && venue.venueId.trim()
        ? venue.venueId.trim()
        : "";

    if (!venueId) {
      const newRef = rtdb.ref("venues").push();
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
      await rtdb.ref(`venues/${venueId}`).update(vUpdates);
    }

    set(`venueAdmins/${venueId}/${uid}`, true);
    set(`venueOwners/${uid}/venueId`, venueId);
    set(`venueOwners/${uid}/approved`, true);
    set(`venueOwners/${uid}/suspended`, false);
    set(`venueOwners/${uid}/linkedAt`, now);
    set(`${appNode}/${uid}/venueId`, venueId);

    await rtdb.ref().update(updates);
    return { ok: true, action: "approve", status: "approved", type, venueId };
  } catch (e) {
    console.error("reviewNightlifeApplication error:", e);

    if (e instanceof functions.https.HttpsError) throw e;

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
  sendArray(res, arr, status = 200, extraHeaders = {}) {
    const payload = Array.isArray(arr) ? arr : [];
    const buf = Buffer.from(JSON.stringify(payload));
    res.status(status);
    res.set({
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "private, max-age=60, no-transform",
      "X-Content-Type-Options": "nosniff",
      "Cross-Origin-Resource-Policy": "cross-origin",
      "Alt-Svc": "clear",
      "Connection": "close",
      "Content-Length": String(buf.length),
      ...extraHeaders,
    });
    res.end(buf);
  },
  withCors(handler) {
    return async (req, res) => {
      try {
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

// --- Drop-in upgrade: stronger hero picker (place near your other FEED helpers) ---
FEED.pickHero = function pickHero(images) {
  if (!Array.isArray(images)) return null;

  // Normalize and enforce https
  const norm = images
    .map(img => ({
      url: typeof img.url === "string" ? img.url.replace(/^http:/i, "https:") : null,
      width: Number(img.width || 0),
      height: Number(img.height || 0),
      ratio: (img.ratio || "").toLowerCase(),
    }))
    .filter(i => !!i.url);

  if (!norm.length) return null;

  // Prefer cinematic/wide flyers (16:9/3:2) at sufficient size
  const preferred = norm
    .filter(i =>
      (i.ratio === "16_9" || i.ratio === "3_2" ||
        Math.abs(i.width / (i.height || 1) - 16 / 9) < 0.08) &&
      i.width >= 1000
    )
    .sort((a, b) => b.width - a.width);
  if (preferred.length) return preferred[0].url;

  // Fallback: largest image available
  const largest = norm.sort((a, b) => (b.width * b.height) - (a.width * a.height));
  return largest[0]?.url || null;
};


// --- Ticketmaster Discovery feed (updated with robust JSON-only responses + detailed logs) ---
exports.feedTicketmaster = fn.https.onRequest(
  FEED.withCors(async (req, res) => {
    const TM_KEY = getTmKey();
    const debug = String(req.query?.debug || "0") === "1";
    const rid = Math.random().toString(36).slice(2, 8);
    const _debug = [];

    const city = (req.query.city || "").toString().trim();
    const startRaw = (req.query.start || "").toString().trim();
    const endRaw = (req.query.end || "").toString().trim();
    const { start, end } = FEED.clampWindow(startRaw, endRaw);

    console.log(`🎫 [TM][${rid}] ↩︎ query`, {
      city,
      start: FEED.zISO(start),
      end: FEED.zISO(end),
      requireImage: req.query?.requireImage,
      imagesFirst: req.query?.imagesFirst,
      debug,
    });

    if (!TM_KEY) {
      console.warn(`🎫 [TM][${rid}] TM_API_KEY missing → returning []`);
      return FEED.sendArray(res, debug ? [{ _debug: [{ error: "TM key missing" }] }] : []);
    }

    const url = new URL("https://app.ticketmaster.com/discovery/v2/events.json");
    url.searchParams.set("apikey", TM_KEY);
    url.searchParams.set("size", "50");
    url.searchParams.set("sort", "date,asc");
    url.searchParams.set("countryCode", "US");
    url.searchParams.set("classificationName", "Music");
    if (city) url.searchParams.set("city", city);
    url.searchParams.set("startDateTime", FEED.zISO(start));
    url.searchParams.set("endDateTime", FEED.zISO(end));

    console.log(`🎫 [TM][${rid}] → ${url.toString()}`);

    let items = [];
    try {
      const resp = await _fetch(url.toString(), { method: "GET" });
      const ct = resp.headers.get("content-type") || "";
      const clen = resp.headers.get("content-length") || "";
      console.log(`🎫 [TM][${rid}] HTTP ${resp.status} ct=${ct} len=${clen}`);

      if (!resp.ok) {
        const t = await resp.text().catch(() => "");
        console.warn(`🎫 [TM][${rid}] non-200 body preview:`, t.slice(0, 200));
        if (debug) _debug.push({ status: resp.status, ct, preview: t.slice(0, 400) });
        return FEED.sendArray(res, debug ? [{ _debug }, ...[]] : []);
      }

      // If upstream sent HTML or something unexpected, guard parse
      if (!/json/i.test(ct)) {
        const t = await resp.text().catch(() => "");
        console.warn(`🎫 [TM][${rid}] unexpected content-type; preview:`, t.slice(0, 200));
        if (debug) _debug.push({ status: resp.status, ct, preview: t.slice(0, 400) });
        return FEED.sendArray(res, debug ? [{ _debug }, ...[]] : []);
      }

      let data;
      try {
        data = await resp.json();
      } catch (e) {
        const t = await _fetch(url.toString(), { method: "GET" })
          .then(r => r.text().catch(() => ""))
          .catch(() => "");
        console.error(`🎫 [TM][${rid}] JSON parse error`, e);
        if (debug) _debug.push({ parseError: String(e), fallbackPreview: t.slice(0, 400) });
        return FEED.sendArray(res, debug ? [{ _debug }, ...[]] : []);
      }

      const list = data?._embedded?.events ?? [];
      console.log(`🎫 [TM][${rid}] events=${list.length}`);

      items = list.map((ev) => {
        const venue = ev?._embedded?.venues?.[0] || {};

        const hero =
          FEED.pickHero(ev?.images) ||
          FEED.pickHero(ev?._embedded?.attractions?.[0]?.images) ||
          (typeof ev?.seatmap?.staticUrl === "string"
            ? ev.seatmap.staticUrl.replace(/^http:/i, "https:")
            : null);

        const when =
          ev?.dates?.start?.dateTime ||
          (ev?.dates?.start?.localDate
            ? `${ev.dates.start.localDate}T${ev.dates.start.localTime || "00:00:00"}Z`
            : new Date());

        const item = {
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
        item.imageURL = item.heroImage; // backward compat
        return item;
      });
    } catch (e) {
      console.error(`🎫 [TM][${rid}] fetch error`, e);
      if (debug) _debug.push({ error: String(e) });
    }

    const before = items.length;

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

    console.log(`🎫 [TM][${rid}] out=${items.length} (filtered from ${before})`);
    return FEED.sendArray(res, debug ? [{ _debug }, ...items] : items);
  })
);

// --- Eventbrite Search feed (updated with robust JSON-only responses + detailed logs) ---
exports.feedEventbrite = fn.https.onRequest(
  FEED.withCors(async (req, res) => {
    const EB_TOKEN = getEbToken();
    const debug = String(req.query?.debug || "0") === "1";
    const rid = Math.random().toString(36).slice(2, 8);
    const _debug = [];

    const city = (req.query.city || "").toString().trim();
    const startRaw = (req.query.start || "").toString().trim();
    const endRaw = (req.query.end || "").toString().trim();
    const { start, end } = FEED.clampWindow(startRaw, endRaw);

    console.log(`🟠 [EB][${rid}] ↩︎ query`, {
      city,
      start: FEED.zISO(start),
      end: FEED.zISO(end),
      requireImage: req.query?.requireImage,
      imagesFirst: req.query?.imagesFirst,
      debug,
    });

    if (!EB_TOKEN) {
      console.warn(`🟠 [EB][${rid}] EVENTBRITE_TOKEN missing → returning []`);
      return FEED.sendArray(
        res,
        debug ? [{ _debug: [{ error: "Eventbrite token missing" }] }] : []
      );
    }

    const url = new URL("https://www.eventbriteapi.com/v3/events/search/");
    url.searchParams.set("sort_by", "date");
    url.searchParams.set("expand", "venue,logo,organizer");
    url.searchParams.set("page_size", "50");
    url.searchParams.set("start_date.range_start", FEED.zISO(start));
    url.searchParams.set("start_date.range_end", FEED.zISO(end));
    if (city) url.searchParams.set("location.address", city);

    console.log(`🟠 [EB][${rid}] → ${url.toString()}`);

    let items = [];
    try {
      const resp = await _fetch(url.toString(), {
        method: "GET",
        headers: { Authorization: `Bearer ${EB_TOKEN}` },
      });
      const ct = resp.headers.get("content-type") || "";
      const clen = resp.headers.get("content-length") || "";
      console.log(`🟠 [EB][${rid}] HTTP ${resp.status} ct=${ct} len=${clen}`);

      if (!resp.ok) {
        const t = await resp.text().catch(() => "");
        console.warn(`🟠 [EB][${rid}] non-200 body preview:`, t.slice(0, 200));
        if (debug) _debug.push({ status: resp.status, ct, preview: t.slice(0, 400) });
        return FEED.sendArray(res, debug ? [{ _debug }, ...[]] : []);
      }

      if (!/json/i.test(ct)) {
        const t = await resp.text().catch(() => "");
        console.warn(`🟠 [EB][${rid}] unexpected content-type; preview:`, t.slice(0, 200));
        if (debug) _debug.push({ status: resp.status, ct, preview: t.slice(0, 400) });
        return FEED.sendArray(res, debug ? [{ _debug }, ...[]] : []);
      }

      let data;
      try {
        data = await resp.json();
      } catch (e) {
        const t = await _fetch(url.toString(), {
          method: "GET",
          headers: { Authorization: `Bearer ${EB_TOKEN}` },
        })
          .then(r => r.text().catch(() => ""))
          .catch(() => "");
        console.error(`🟠 [EB][${rid}] JSON parse error`, e);
        if (debug) _debug.push({ parseError: String(e), fallbackPreview: t.slice(0, 400) });
        return FEED.sendArray(res, debug ? [{ _debug }, ...[]] : []);
      }

      const list = Array.isArray(data?.events) ? data.events : [];
      console.log(`🟠 [EB][${rid}] events=${list.length}`);

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
      console.error(`🟠 [EB][${rid}] fetch error`, e);
      if (debug) _debug.push({ error: String(e) });
    }

    const before = items.length;

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

    console.log(`🟠 [EB][${rid}] out=${items.length} (filtered from ${before})`);
    return FEED.sendArray(res, debug ? [{ _debug }, ...items] : items);
  })
);

// =========================
// OPTIONAL dynamic modules (unchanged)
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
// ACCEPT INVITES (callable)
//--------------
exports.acceptInvite = functions.https.onCall(async (data, context) => {
  const auth = context.auth;
  const inviterId = data && data.inviterId;
  const inviteeId = data && data.inviteeId;

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

  const acceptRef = rtdb.ref(`invitesAccepted/${inviteeId}`);

  const acceptTxn = await acceptRef.transaction((current) => {
    if (current) return;
    return {
      inviterId,
      inviteeId,
      timestamp: Date.now(),
      status: 'accepted',
    };
  }, { applyLocally: false });

  if (!acceptTxn.committed) {
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

  const circleRef = rtdb.ref(`users/${inviterId}/circleSize`);
  const circleTxn = await circleRef.transaction(
    (val) => (typeof val === 'number' ? val + 1 : 1),
    { applyLocally: false }
  );
  const circleSize = circleTxn.snapshot.val() || 1;

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

  const updates = {};
  updates[`users/${inviterId}/badgeTier`] = badge;
  updates[`contacts/${inviterId}/${inviteeId}`] = true;
  updates[`contacts/${inviteeId}/${inviterId}`] = true;

  await rtdb.ref().update(updates);

  return {
    status: 'accepted',
    circleSize,
    badgeTier: badge,
  };
});

async function getCircleSize(uid) {
  const snap = await rtdb.ref(`users/${uid}/circleSize`).get();
  return snap.exists() ? snap.val() : 0;
}
async function getBadgeTier(uid) {
  const snap = await rtdb.ref(`users/${uid}/badgeTier`).get();
  return snap.exists() ? snap.val() : 'white';
}

// Seed defaults if signup flow didn’t
exports.ensureUserDefaults = functions.https.onCall(async (_, context) => {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError('unauthenticated', 'Sign in required.');
  }
  const uid = context.auth.uid;
  const ref = rtdb.ref(`users/${uid}`);
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
const REGION = 'us-central1';
const chatId = (a, b) => [a, b].sort().join('_');

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
    const ref = firestore.collection('inviteCodes').doc(code);
    const snap = await ref.get();
    if (!snap.exists) return code;
  }
  throw new Error('Could not generate unique invite code after several attempts');
}

async function ensureMutualContacts(aUid, bUid, status, source) {
  const aRef = firestore.collection('users').doc(aUid).collection('contacts').doc(bUid);
  const bRef = firestore.collection('users').doc(bUid).collection('contacts').doc(aUid);
  const dcRef = firestore.collection('directChats').doc(chatId(aUid, bUid));

  const [aSnap, bSnap, dcSnap] = await Promise.all([aRef.get(), bRef.get(), dcRef.get()]);
  const active = status === 'active';

  const batch = firestore.batch();

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

// Assign short invite code to NEW users
exports.onUserCreated = functions
  .region(REGION)
  .firestore.document('users/{uid}')
  .onCreate(async (snap, ctx) => {
    const uid = ctx.params.uid;
    const data = snap.data() || {};
    if (data.inviteCode) return;

    const code = await generateUniqueCode();
    await Promise.all([
      snap.ref.set({ inviteCode: code }, { merge: true }),
      firestore.collection('inviteCodes').doc(code).set({
        uid,
        createdAt: serverTimestamp(),
      }),
    ]);
  });

// When user doc gets a referrer, link both sides + active DM
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
    if (referrer === uid) return;
    if (prevRef === referrer) return;

    await ensureMutualContacts(referrer, uid, 'active', 'invite');
    await change.after.ref.set({ referralProcessed: true }, { merge: true });
  });

// If either side activates a pending contact, mirror & clear chat.pending
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

    const mirrorRef = firestore.collection('users').doc(other).collection('contacts').doc(uid);
    const dcRef = firestore.collection('directChats').doc(chatId(uid, other));

    const [mirrorSnap, dcSnap] = await Promise.all([mirrorRef.get(), dcRef.get()]);

    const batch = firestore.batch();

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

// ---------- ONE-TIME backfill invite codes ----------
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

      const limit = Math.min(parseInt(String(req.query.limit || '200'), 10), 500);
      const after = req.query.after ? String(req.query.after) : undefined;

      let q = firestore.collection('users').orderBy(admin.firestore.FieldPath.documentId()).limit(limit);
      if (after) q = q.startAfter(after);

      const snap = await q.get();
      if (snap.empty) {
        res.json({ processed: 0, assigned: 0, fixedMappings: 0, nextAfter: null });
        return;
      }

      let processed = 0;
      let assigned = 0;
      let fixedMappings = 0;

      const batch = firestore.batch();

      for (const doc of snap.docs) {
        processed++;
        const uid = doc.id;
        const data = doc.data() || {};
        const existingCode = data.inviteCode;

        if (!existingCode) {
          const code = await generateUniqueCode();
          batch.set(doc.ref, { inviteCode: code }, { merge: true });
          batch.set(firestore.collection('inviteCodes').doc(code), { uid, createdAt: serverTimestamp() });
          assigned++;
        } else {
          const mapRef = firestore.collection('inviteCodes').doc(existingCode);
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

/* ================================
   NEW: Twitter/X-style RSS pipeline
   - rssBundle: pre-normalize feed items with thumb + aspect
   - imgThumb: image resize proxy with sharp
   ================================ */

// Helpers for rssBundle
const parser = new RSSParser({
  timeout: 15000,
  requestOptions: {
    headers: {
      "User-Agent": "BlackApp/1.0 (+https://blackapp.io)",
      "Accept": "application/rss+xml, application/atom+xml, application/xml;q=0.9,*/*;q=0.8",
    },
  },
});
const looksLikeLogo = (u = "") => {
  const s = String(u).toLowerCase();
  return (
    /\.(svg|gif|ico)(\?|#|$)/.test(s) ||
    /(logo|icon|avatar|placeholder|default|badge|sprite|favicon|brand|masthead)/.test(s)
  );
};
const findImgInHtml = (html = "") => {
  const m = String(html).match(/<img[^>]+src=["']([^"']+)["']/i);
  return m && m[1] ? m[1] : "";
};
const safeHttps = (u = "") => (u.startsWith("http://") ? "https://" + u.slice(7) : u);
const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n || 0));

exports.imgThumb = fn.https.onRequest(async (req, res) => {
  try {
    const url = String(req.query.url || "");
    if (!/^https?:\/\//i.test(url)) return res.status(400).send("bad url");

    const fmt = String(req.query.fmt || "webp").toLowerCase();
    const w = clamp(parseInt(req.query.w, 10) || 800, 120, 2000);

    const resp = await undiciFetch(url, { redirect: "follow" });
    if (!resp.ok) return res.status(resp.status).send("upstream " + resp.status);
    const buf = Buffer.from(await resp.arrayBuffer());

    let pipe = sharp(buf).resize({ width: w, withoutEnlargement: true });
    if (fmt === "jpg" || fmt === "jpeg") pipe = pipe.jpeg({ quality: 78, mozjpeg: true });
    else pipe = pipe.webp({ quality: 75 });

    const out = await pipe.toBuffer();

    res.set("Cache-Control", "public, max-age=86400, s-maxage=86400");
    res.set("Content-Type", fmt === "jpg" || fmt === "jpeg" ? "image/jpeg" : "image/webp");
    return res.status(200).send(out);
  } catch (e) {
    console.error("imgThumb error", e);
    return res.status(500).send("thumb error");
  }
});

exports.rssBundle = fn.https.onRequest(async (req, res) => {
  if (req.method !== "POST") return res.status(405).send("Use POST JSON");
  try {
    const body = req.body || {};
    const feeds = Array.isArray(body.feeds) ? body.feeds : [];
    if (!feeds.length) return res.status(400).json({ ok: false, error: "feeds required" });

    const perFeedLimit = clamp(body.perFeedLimit || 6, 1, 20);
    const thumbWidth = clamp(body.thumbWidth || 800, 200, 1600);

    const items = (await Promise.all(
      feeds.map(async (f) => {
        try {
          const resp = await fetch(f.url, {
            redirect: "follow",
            headers: { "User-Agent": "BlackApp/1.0" },
          });
          if (!resp.ok) {
            console.warn("feed upstream", f.url, resp.status);
            return [];
          }
          const xml = await resp.text();
          const feed = await parser.parseString(xml);
          const now = Date.now();

          let list = (feed.items || []).map((it) => {
            const html = it["content:encoded"] || it.content || it.summary || "";
            let image =
              it.enclosure?.url ||
              it["media:content"]?.url ||
              it["media:thumbnail"]?.url ||
              it.itunes?.image ||
              feed.image?.url ||
              findImgInHtml(html) ||
              "";

            image = safeHttps(image);
            if (looksLikeLogo(image)) image = "";

            const link = safeHttps(it.link || "");
            const title = (it.title || "").trim();
            const guid = it.guid || link || title || (Math.random() + "");

            return {
              id: guid,
              guid,
              title,
              link,
              summary: (it.contentSnippet || it.summary || it.content || "").trim().slice(0, 280),
              pubDate: it.isoDate ? Date.parse(it.isoDate)
                                  : (it.pubDate ? Date.parse(it.pubDate) : now),
              image,
              kind: f.kind || "nightlife",
              source: f.url,
            };
          });

          list = list.filter((x) => x.image && x.title && x.link);
          list.sort((a, b) => b.pubDate - a.pubDate);
          list = list.slice(0, perFeedLimit);

          const project = process.env.GCLOUD_PROJECT || process.env.GCLOUD_PROJECT_NUMBER || "";
          const thumbBase = `https://us-central1-${project}.cloudfunctions.net/imgThumb`;

          return list.map((x) => ({
            ...x,
            thumb: `${thumbBase}?url=${encodeURIComponent(x.image)}&w=${thumbWidth}&fmt=webp`,
            aspect: 0.5625, // 16:9 default; can refine if you compute real sizes
          }));
        } catch (e) {
          console.error("feed parse error", f.url, e);
          return [];
        }
      })
    )).flat();

    const seen = new Set();
    const deduped = [];
    for (const it of items) {
      const key = it.guid || it.link || it.title;
      if (seen.has(key)) continue;
      seen.add(key);
      deduped.push(it);
    }

    deduped.sort((a, b) => b.pubDate - a.pubDate);

    res.set("Cache-Control", "public, max-age=120, s-maxage=300");
    return res.json({
      ok: true,
      items: deduped.map((x) => ({
        id: x.id,
        title: x.title,
        link: x.link,
        summary: x.summary,
        pubDate: x.pubDate,
        image: x.image,
        thumb: x.thumb,
        aspect: x.aspect,
        kind: x.kind,
        source: x.source,
      })),
    });
  } catch (e) {
    console.error("rssBundle error", e);
    return res.status(500).json({ ok: false, error: "bundle error" });
  }
});
