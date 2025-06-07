const functions = require("firebase-functions");
const admin = require("firebase-admin");
const braintree = require("braintree");
const cors = require("cors")({ origin: true });

admin.initializeApp();

const gateway = new braintree.BraintreeGateway({
  environment: braintree.Environment.Sandbox,
  merchantId: "bv3gft4qcdkrznn2",
  publicKey: "869df6w9p4pks5ch",
  privateKey: "2703c4d9fc5a3e1e9ec7fde9641a2951"
});

// 1️⃣ generateClientToken
exports.generateClientToken = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
    try {
      const response = await gateway.clientToken.generate({});
      res.status(200).send({ clientToken: response.clientToken });
    } catch (error) {
      console.error("Token generation failed:", error);
      res.status(500).send({ error: "Token generation failed" });
    }
  });
});

// 2️⃣ createTransaction
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

      if (!result.success) {
        throw new Error(result.message);
      }

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
      console.error("Transaction failed:", error);
      res.status(500).send({ error: error.message });
    }
  });
});

// 3️⃣ getCheckoutURL
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

// 4️⃣ sendNewMessageNotification
exports.sendNewMessageNotification = functions.firestore
  .document("chats/{chatId}/messages/{messageId}")
  .onCreate(async (snap, context) => {
    const messageData = snap.data();
    const recipientId = messageData.recipientId;
    const senderName = messageData.senderName || "Someone";
    const messageText = messageData.text || "New message";

    console.log("📨 Message data:", messageData);
    console.log("📨 Recipient ID:", recipientId);

    if (!recipientId) {
      console.log("⚠️ Missing recipient ID.");
      return;
    }

    const userDoc = await admin.firestore().collection("users").doc(recipientId).get();
    const fcmToken = userDoc.data()?.fcmToken;
    console.log("📨 FCM Token:", fcmToken);

    if (!fcmToken) {
      console.log("⚠️ No FCM token for recipient:", recipientId);
      return;
    }

    const payload = {
      notification: {
        title: `New message from ${senderName}`,
        body: messageText.substring(0, 50),
        sound: "default"
      },
      data: {
        type: "chat",
        chatId: context.params.chatId
      }
    };

    try {
      const response = await admin.messaging().sendToDevice(fcmToken, payload);
      console.log("✅ FCM response:", response);
    } catch (error) {
      console.error("❌ FCM send error:", error);
    }
  });
