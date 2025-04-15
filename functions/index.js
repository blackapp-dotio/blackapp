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
    const { amount, paymentMethodNonce, type } = req.body;

    if (!amount || !paymentMethodNonce) {
      return res.status(400).send({ error: "Missing amount or paymentMethodNonce" });
    }

    const total = (parseFloat(amount) * 1.02).toFixed(2); // 2% fee

    try {
      const result = await gateway.transaction.sale({
        amount: total,
        paymentMethodNonce,
        options: { submitForSettlement: true }
      });

      if (!result.success) {
        throw new Error(result.message);
      }

      res.status(200).send(result);
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

