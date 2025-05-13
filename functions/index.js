const functions = require("firebase-functions");
const admin = require("firebase-admin");
const braintree = require("braintree");
const cors = require("cors")({ origin: true });

admin.initializeApp();

// ✅ Use your actual Braintree sandbox credentials
const gateway = new braintree.BraintreeGateway({
  environment: braintree.Environment.Sandbox,
  merchantId: "bv3gft4qcdkrznn2",
  publicKey: "869df6w9p4pks5ch",
  privateKey: "2703c4d9fc5a3e1e9ec7fde9641a2951"
});

// ✅ 1. Public client token generator for Drop-in
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

// ✅ 2. Public transaction creation with 2% platform fee
exports.createTransaction = functions.https.onRequest((req, res) => {
  cors(req, res, async () => {
    const {
      amount,
      paymentMethodNonce,
      userId,
      eventId,
      eventName,
      type,
      quantity
    } = req.body;

    if (!amount || !paymentMethodNonce || !userId || !eventId || !eventName || !type || !quantity) {
      return res.status(400).send({ error: "Missing required transaction fields" });
    }

    const baseAmount = parseFloat(amount);
    const total = (baseAmount * 1.02).toFixed(2); // 2% platform fee
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

      // ✅ Save purchase data to Firebase
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

// ✅ 3. Public checkout URL generator
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


