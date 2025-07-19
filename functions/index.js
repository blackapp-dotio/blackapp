const admin = require("firebase-admin");
const braintree = require("braintree");
const cors = require("cors")({ origin: true });
const functions = require("firebase-functions/v1");
const fetch = (...args) => import('node-fetch').then(({ default: fetch }) => fetch(...args));

if (!admin.apps.length) {
  admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  databaseURL: "https://blackappios-default-rtdb.firebaseio.com" // or correct URL from your Firebase Console
});

}

const gateway = new braintree.BraintreeGateway({
  environment: braintree.Environment.Sandbox,
  merchantId: "bv3gft4qcdkrznn2",
  publicKey: "869df6w9p4pks5ch",
  privateKey: "2703c4d9fc5a3e1e9ec7fde9641a2951"
});

exports.generateClientToken = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
    try {
      const response = await gateway.clientToken.generate({});
      res.status(200).send({ clientToken: response.clientToken });
    } catch (error) {
      console.error("❌ Token generation failed:", error);
      res.status(500).send({ error: "Token generation failed" });
    }
  });
});

exports.createTransaction = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
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
      totalWithFee = 0, // Use this as the payment amount
      eventTime // Optional: for reminders and display
    } = req.body;

    // Log full incoming payload for debugging
    console.log("📥 Incoming request body:", req.body);

    // Parse all numeric fields
    const ticketQtyNum = parseInt(ticketQty) || 0;
    const tableQtyNum = parseInt(tableQty) || 0;
    const ticketPriceNum = parseFloat(ticketPrice) || 0;
    const tablePriceNum = parseFloat(tablePrice) || 0;
    let platformFeeNum = parseFloat(platformFee) || 0;
    let amountToCharge = parseFloat(totalWithFee);

    // Fallback to manual total calculation if frontend amount is broken
    const fallbackBase = ticketQtyNum * ticketPriceNum + tableQtyNum * tablePriceNum;
    const fallbackFee = +(fallbackBase * 0.02).toFixed(2);
    const fallbackTotal = +(fallbackBase + fallbackFee).toFixed(2);

    if (isNaN(amountToCharge) || amountToCharge <= 0) {
      console.warn("⚠️ Invalid totalWithFee from frontend. Falling back to server-calculated total.");
      amountToCharge = fallbackTotal;
    }

    // Validate essential fields
    if (!paymentMethodNonce || !userId || !eventId || !eventName) {
      return res.status(400).send({ error: "❌ Missing required fields" });
    }

    // Determine quantity and type for compatibility with PurchaseModel
    const totalQty = ticketQtyNum + tableQtyNum;
    let type = "ticket";
    if (ticketQtyNum > 0 && tableQtyNum > 0) {
      type = "mixed";
    } else if (tableQtyNum > 0 && ticketQtyNum === 0) {
      type = "table";
    }

    // Log totals
    console.log("🧮 Totals => Base:", fallbackBase.toFixed(2), "Fee:", fallbackFee.toFixed(2), "Charged:", amountToCharge.toFixed(2));

    try {
      const result = await gateway.transaction.sale({
        amount: amountToCharge.toFixed(2),
        paymentMethodNonce,
        options: { submitForSettlement: true }
      });

      if (!result.success) {
        throw new Error(result.message || "Transaction unsuccessful");
      }

      const timestamp = Date.now();
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
        paymentMethod: "card"
      });

      console.log("✅ Transaction successful:", result.transaction.id);
      res.status(200).send({ success: true, transactionId: result.transaction.id });

    } catch (error) {
      console.error("❌ Transaction failed:", error);
      res.status(500).send({ error: error.message || "Unknown server error" });
    }
  });
});

exports.scheduleEventReminders = functions.pubsub
  .schedule("every 1 hours")
  .onRun(async () => {
    const now = Date.now();
    const in24Hours = now + 24 * 60 * 60 * 1000;

    const snapshot = await admin.database().ref("purchases").once("value");

    snapshot.forEach(userSnap => {
      userSnap.forEach(purchaseSnap => {
        const data = purchaseSnap.val();
        const { eventTime, eventName = "Event", eventId, userId } = data;

        if (!eventTime || !userId) return;

        const diff = eventTime - now;
        const is24hrWindow = diff > 0 && diff < 60 * 60 * 1000;

        if (is24hrWindow) {
          admin
            .database()
            .ref(`users/${userId}/onesignalUserId`)
            .once("value")
            .then(tokenSnap => {
              const oneSignalId = tokenSnap.val();
              if (!oneSignalId) return;

              const payload = {
                app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
                include_player_ids: [oneSignalId],
                headings: { en: "🎉 Event Reminder" },
                contents: { en: `Your event "${eventName}" is in 24 hours.` },
                data: { type: "event_reminder", eventId, eventName }
              };

              return fetch("https://onesignal.com/api/v1/notifications", {
                method: "POST",
                headers: {
                  "Content-Type": "application/json",
                  Authorization: "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq"
                },
                body: JSON.stringify(payload)
              });
            });
        }
      });
    });

    return null;
  });


exports.getPlatformRevenue = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
    try {
      const snapshot = await admin.database().ref("purchases").once("value");

      let totalRevenue = 0;
      let platformEarnings = 0;
      let totalEvents = new Set();
      let ticketsSold = 0;

      snapshot.forEach(userSnap => {
        userSnap.forEach(purchaseSnap => {
          const data = purchaseSnap.val();
          totalEvents.add(data.eventId);
          platformEarnings += parseFloat(data.platformFee || 0);
          totalRevenue += parseFloat(data.totalAmount || 0);
          ticketsSold += parseInt(data.ticketQty || 0);
        });
      });

      res.status(200).send({
        platformEarnings: platformEarnings.toFixed(2),
        totalRevenue: totalRevenue.toFixed(2),
        totalEvents: totalEvents.size,
        ticketsSold
      });
    } catch (err) {
      console.error("❌ Revenue summary failed:", err);
      res.status(500).send({ error: err.message });
    }
  });
});



exports.getCheckoutURL = functions.https.onRequest((req, res) => {
  cors(req, res, () => {
    const { amount, description } = req.query;

    if (!amount || !description) {
      return res.status(400).send({ error: "Missing amount or description" });
    }

    const redirectURL = `https://blackappios.web.app/?amount=${amount}&desc=${encodeURIComponent(description)}`;
    res.status(200).send({ checkoutURL: redirectURL });
  });
});

// Helper for logging
function logStamp(tag) {
  console.log(`🕓 [${new Date().toISOString()}] ${tag}`);
}

// ✅ Direct Chat Notification with Dynamic Sender Name
exports.sendNewMessageNotification = functions.firestore
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

    // 🔍 Fetch recipient's OneSignal ID from Realtime DB
    const tokenSnap = await admin.database().ref(`users/${recipientId}/onesignalUserId`).once("value");
    const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;

    if (!oneSignalId) {
      console.warn(`❌ No OneSignal ID found for user ${recipientId}`);
      return;
    }

    // 🧠 Fetch sender's name from Realtime DB
    let senderName = "Someone";
    try {
      const senderSnap = await admin.database().ref(`users/${senderId}/name`).once("value");
      if (senderSnap.exists()) {
        senderName = senderSnap.val();
      }
    } catch (err) {
      console.warn(`⚠️ Could not fetch sender name for ${senderId}`, err);
    }

    // 📦 OneSignal payload
    const payload = {
      app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
      include_player_ids: [oneSignalId],
      headings: { en: `New message from ${senderName}` },
      contents: { en: text.substring(0, 100) },
      data: {
        chatId,
        senderId,
        senderName,
        type: "chat"
      }
    };

    // 🚀 Send notification
    try {
      const response = await fetch("https://onesignal.com/api/v1/notifications", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq"
        },
        body: JSON.stringify(payload)
      });

      const result = await response.json();
      console.log("📤 Notification sent (direct):", result);
    } catch (err) {
      console.error("🔥 Failed to send direct notification:", err);
    }
  });

exports.sendNewGroupMessageNotification = functions.firestore
  .document("groups/{groupId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Group message trigger");

    const data = snap.data();
    const { senderId, text = "New group message" } = data;
    const groupId = context.params.groupId;

    console.log(`📨 New message in group: ${groupId}, sender: ${senderId}, text: ${text}`);

    // Fetch sender name from Firestore
    let senderName = "Someone";
    try {
      const senderSnap = await admin.firestore().collection("users").doc(senderId).get();
      if (senderSnap.exists) senderName = senderSnap.data().name || "Someone";
    } catch (err) {
      console.warn(`⚠️ Could not fetch sender name for ${senderId}`, err);
    }

    // Fetch group members from subcollection
    let memberIds = [];
    try {
      const membersSnap = await admin.firestore().collection(`groups/${groupId}/members`).get();
      memberIds = membersSnap.docs.map(doc => doc.id);
      console.log(`👥 Fetched ${memberIds.length} member(s)`);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await admin.database().ref(`users/${userId}/onesignalUserId`).once("value");
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;

        if (!oneSignalId) {
          console.warn(`⛔ No OneSignal ID for member ${userId}`);
          continue;
        }

        const payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: `New message from ${senderName}` },
          contents: { en: text.substring(0, 100) },
          data: {
            groupId,
            senderId,
            senderName,
            type: "group"
          }
        };

        const response = await fetch("https://onesignal.com/api/v1/notifications", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq"
          },
          body: JSON.stringify(payload)
        });

        const result = await response.json();
        console.log(`📤 Notification sent to ${userId}:`, result);

      } catch (err) {
        console.error(`🔥 Failed to notify ${userId}:`, err);
      }
    }
  });

exports.sendGroupMessageLikeNotification = functions.firestore
  .document("groups/{groupId}/messages/{messageId}")
  .onUpdate(async (change, context) => {
    logStamp("📡 OneSignal: Group like trigger");

    const before = change.before.data();
    const after = change.after.data();

    const beforeLikes = before.likes || [];
    const afterLikes = after.likes || [];
    const newLikes = afterLikes.filter(uid => !beforeLikes.includes(uid));
    if (newLikes.length === 0) return;

    const senderId = newLikes[0];
    const { groupId, messageId } = context.params;

    console.log(`❤️ Message ${messageId} liked by ${senderId} in group ${groupId}`);

    let memberIds = [];
    try {
      const membersSnap = await admin.firestore().collection(`groups/${groupId}/members`).get();
      memberIds = membersSnap.docs.map(doc => doc.id);
      console.log(`👥 Found ${memberIds.length} group members`);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await admin.database().ref(`users/${userId}/onesignalUserId`).once("value");
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;

        if (!oneSignalId) {
          console.warn(`⛔ No OneSignal ID for like notification user ${userId}`);
          continue;
        }

        const payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: "❤️ A message was liked!" },
          contents: { en: "Tap to view the liked message." },
          data: {
            groupId,
            messageId,
            type: "group_like"
          }
        };

        const response = await fetch("https://onesignal.com/api/v1/notifications", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq"
          },
          body: JSON.stringify(payload)
        });

        const result = await response.json();
        console.log(`📤 Like notification sent to ${userId}:`, result);

      } catch (err) {
        console.error(`🔥 Failed to send like notification to ${userId}:`, err);
      }
    }
  });


exports.sendGroupMessageCommentNotification = functions.firestore
  .document("groups/{groupId}/messages/{messageId}/comments/{commentId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Group comment trigger");

    const { groupId, messageId } = context.params;
    const comment = snap.data();
    const senderId = comment.userId;
    const commentText = comment.text || "New comment";

    console.log(`💬 New comment on message ${messageId} in group ${groupId} by ${senderId}`);

    let memberIds = [];
    try {
      const membersSnap = await admin.firestore().collection(`groups/${groupId}/members`).get();
      memberIds = membersSnap.docs.map(doc => doc.id);
      console.log(`👥 Loaded ${memberIds.length} group members`);
    } catch (err) {
      console.error(`🔥 Failed to fetch group members for ${groupId}`, err);
      return;
    }

    for (const userId of memberIds) {
      if (userId === senderId) continue;

      try {
        const tokenSnap = await admin.database().ref(`users/${userId}/onesignalUserId`).once("value");
        const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;

        if (!oneSignalId) {
          console.warn(`⛔ No OneSignal ID for comment notify user ${userId}`);
          continue;
        }

        const payload = {
          app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
          include_player_ids: [oneSignalId],
          headings: { en: "💬 New Comment in Group Chat" },
          contents: { en: commentText.substring(0, 100) },
          data: {
            groupId,
            messageId,
            type: "group_comment"
          }
        };

        const response = await fetch("https://onesignal.com/api/v1/notifications", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq"
          },
          body: JSON.stringify(payload)
        });

        const result = await response.json();
        console.log(`📤 Comment notification sent to ${userId}:`, result);

      } catch (err) {
        console.error(`🔥 Failed to send comment notification to ${userId}:`, err);
      }
    }
  });




exports.sendEventReminderNotification = functions.database
  .ref("purchases/{userId}/{purchaseId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Event reminder trigger");

    const { userId } = context.params;
    const data = snap.val();
    const { eventName = "Your Event", eventId, eventTime } = data;

    // ✅ Fetch OneSignal ID from Realtime DB
    const tokenSnap = await admin.database().ref(`users/${userId}/oneSignalId`).once("value");
    const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;

    if (!oneSignalId) {
      console.warn(`❌ No OneSignal ID for user ${userId}`);
      return;
    }

    const payload = {
      app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
      include_player_ids: [oneSignalId],
      headings: { en: "🎟 Event Reminder" },
      contents: { en: `Don't miss ${eventName}! It starts soon.` },
      data: {
        eventId,
        eventName,
        eventTime,
        type: "event_reminder"
      }
    };

    try {
      const response = await fetch("https://onesignal.com/api/v1/notifications", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Basic os_v2_app_ne3gxoznq5cldeq4h7jmxkhp7ruw3us5chieq44pjsibxepuhuu6g5whoglp4np5whffwb72r6ybupdxcevuso2oilvzdldcf4jajsq"
        },
        body: JSON.stringify(payload)
      });

      const result = await response.json();
      console.log(`📤 Event reminder sent to ${userId}:`, result);
    } catch (err) {
      console.error(`🔥 Event reminder failed for ${userId}:`, err);
    }
  });

exports.logManualPurchase = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
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
      eventTime
    } = req.body;

    // Validate required fields
    if (!userId || !eventId || !eventName) {
      return res.status(400).send({ error: "❌ Missing required fields" });
    }

    // Parse all numbers
    const ticketQtyNum = parseInt(ticketQty) || 0;
    const tableQtyNum = parseInt(tableQty) || 0;
    const ticketPriceNum = parseFloat(ticketPrice) || 0;
    const tablePriceNum = parseFloat(tablePrice) || 0;
    const baseAmountNum = parseFloat(baseTotal) || 0;
    const totalAmountNum = parseFloat(totalWithFee) || 0;
    const platformFeeNum = parseFloat(platformFee) || 0;
    const eventTimeNum = eventTime ? parseInt(eventTime) : null;

    // Determine unified quantity and type
    const totalQty = ticketQtyNum + tableQtyNum;
    let type = "ticket";
    if (ticketQtyNum > 0 && tableQtyNum > 0) {
      type = "mixed";
    } else if (tableQtyNum > 0 && ticketQtyNum === 0) {
      type = "table";
    }

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
        eventTime: eventTimeNum
      });

      console.log("✅ Logged manual purchase for:", userId, "→", eventName);
      res.status(200).send({ success: true });
    } catch (error) {
      console.error("❌ Failed to log manual purchase:", error);
      res.status(500).send({ error: error.message });
    }
  });
});

