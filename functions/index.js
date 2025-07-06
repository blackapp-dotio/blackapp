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
    const { amount, paymentMethodNonce, userId, eventId, eventName, type, quantity } = req.body;

    if (!amount || !paymentMethodNonce || !userId || !eventId || !eventName || !type || !quantity) {
      return res.status(400).send({ error: "Missing required transaction fields" });
    }

    const baseAmount = parseFloat(amount);
    const total = (baseAmount * 1.02).toFixed(2);
    const platformFee = (total - baseAmount).toFixed(2);

    try {
      const result = await gateway.transaction.sale({
        amount: total,
        paymentMethodNonce,
        options: { submitForSettlement: true }
      });

      if (!result.success) throw new Error(result.message);

      const ref = admin.database().ref(`purchases/${userId}`).push();
      const timestamp = Date.now();

      await ref.set({
        id: ref.key,
        eventId,
        eventName,
        type,
        quantity,
        amount: total,
        baseAmount: baseAmount.toFixed(2),
        platformFee,
        timestamp
      });

      res.status(200).send({ success: true, transactionId: result.transaction.id });
    } catch (error) {
      console.error("❌ Transaction failed:", error);
      res.status(500).send({ error: error.message });
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
  .document("groupChats/{chatId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Group message trigger");

    const data = snap.data();
    const { senderId, text = "New group message" } = data;
    const chatId = context.params.chatId;

    // 🧠 Fetch sender name from Realtime DB
    let senderName = "Someone";
    try {
      const nameSnap = await admin.database().ref(`users/${senderId}/name`).once("value");
      if (nameSnap.exists()) {
        senderName = nameSnap.val();
      }
    } catch (err) {
      console.warn(`⚠️ Could not fetch sender name for ${senderId}`, err);
    }

    // 🔍 Get group members from Firestore
    const groupSnap = await admin.firestore().collection("groupChats").doc(chatId).get();
    const members = groupSnap.exists ? groupSnap.data().members || [] : [];

    for (const userId of members) {
      if (userId === senderId) continue;

      const tokenSnap = await admin.database().ref(`users/${userId}/oneSignalId`).once("value");
      const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;

      if (!oneSignalId) {
        console.warn(`⛔ No OneSignal ID for group member ${userId}`);
        continue;
      }

      const payload = {
        app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
        include_player_ids: [oneSignalId],
        headings: { en: `New group message from ${senderName}` },
        contents: { en: text.substring(0, 100) },
        data: {
          chatId,
          senderId,
          senderName,
          type: "group"
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
        console.log(`📤 Group notification sent to ${userId}:`, result);
      } catch (err) {
        console.error(`🔥 Failed to send group notification to ${userId}:`, err);
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

exports.sendGroupMessageCommentNotification = functions.firestore
  .document("groupChats/{chatId}/messages/{messageId}/comments/{commentId}")
  .onCreate(async (snap, context) => {
    logStamp("📡 OneSignal: Group comment trigger");

    const { chatId, messageId } = context.params;
    const comment = snap.data();
    const senderId = comment.userId;
    const commentText = comment.text || "New comment";

    // Fetch group members
    const groupSnap = await admin.firestore().collection("groupChats").doc(chatId).get();
    const members = groupSnap.exists ? groupSnap.data().members || [] : [];

    for (const userId of members) {
      if (userId === senderId) continue;

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
          chatId,
          messageId,
          type: "group_comment"
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
        console.log(`📤 Comment notification sent to ${userId}:`, result);
      } catch (err) {
        console.error(`🔥 Failed to send comment notification to ${userId}:`, err);
      }
    }
  });

exports.sendGroupMessageLikeNotification = functions.firestore
  .document("groupChats/{chatId}/messages/{messageId}")
  .onUpdate(async (change, context) => {
    logStamp("📡 OneSignal: Group like trigger");

    const before = change.before.data();
    const after = change.after.data();

    const beforeLikes = before.likes || [];
    const afterLikes = after.likes || [];
    const newLikes = afterLikes.filter(uid => !beforeLikes.includes(uid));

    if (newLikes.length === 0) return;

    const senderId = newLikes[0];
    const { chatId, messageId } = context.params;

    // Fetch group members
    const groupSnap = await admin.firestore().collection("groupChats").doc(chatId).get();
    const members = groupSnap.exists ? groupSnap.data().members || [] : [];

    for (const userId of members) {
      if (userId === senderId) continue;

      const tokenSnap = await admin.database().ref(`users/${userId}/onesignalUserId`).once("value");
      const oneSignalId = tokenSnap.exists() ? tokenSnap.val() : null;
      if (!oneSignalId) {
        console.warn(`⛔ No OneSignal ID for like notify user ${userId}`);
        continue;
      }

      const payload = {
        app_id: "69366bbb-2d87-44b1-921c-3fd2cba8effc",
        include_player_ids: [oneSignalId],
        headings: { en: "❤️ Someone liked a group message" },
        contents: { en: "Tap to see what they liked!" },
        data: {
          chatId,
          messageId,
          type: "group_like"
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
        console.log(`📤 Like notification sent to ${userId}:`, result);
      } catch (err) {
        console.error(`🔥 Failed to send like notification to ${userId}:`, err);
      }
    }
  });
