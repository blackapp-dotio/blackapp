const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const https = require("https");

const db = admin.firestore();

/**
 * Small helper to dedupe truthy string arrays.
 */
function uniqueStrings(values = []) {
  return [...new Set(values.filter((v) => typeof v === "string" && v.trim()))];
}

/**
 * Normalize a message preview for notifications/inbox rows.
 */
function buildPreviewText(message = {}) {
  const previewText = typeof message.previewText === "string" ? message.previewText.trim() : "";
  const text = typeof message.text === "string" ? message.text.trim() : "";
  const messageType = typeof message.messageType === "string" ? message.messageType.trim() : "";

  if (previewText) return previewText;
  if (text) return text;
  if (messageType === "gif") return "sent a GIF";
  return "New message";
}

/**
 * Pull push targets from a user document.
 * Adjust these keys if your app stores them differently.
 */
function extractPushTargets(userData = {}) {
  const oneSignalPlayerId =
    typeof userData.oneSignalPlayerId === "string" ? userData.oneSignalPlayerId.trim() :
    typeof userData.onesignalUserId === "string" ? userData.onesignalUserId.trim() :
    "";

  const oneSignalPlayerIds = Array.isArray(userData.oneSignalPlayerIds)
    ? userData.oneSignalPlayerIds
    : [];

  const pushToken =
    typeof userData.pushToken === "string" ? userData.pushToken.trim() :
    typeof userData.fcmToken === "string" ? userData.fcmToken.trim() :
    "";

  const pushTokens =
    Array.isArray(userData.pushTokens) ? userData.pushTokens :
    Array.isArray(userData.fcmTokens) ? userData.fcmTokens :
    [];

  return {
    oneSignalPlayerIds: uniqueStrings([oneSignalPlayerId, ...oneSignalPlayerIds]),
    fcmTokens: uniqueStrings([pushToken, ...pushTokens]),
  };
}

/**
 * Optional OneSignal sender.
 * Requires functions config:
 * firebase functions:config:set onesignal.app_id="YOUR_APP_ID" onesignal.api_key="YOUR_REST_API_KEY"
 */
async function sendOneSignalNotification({ playerIds, headings, contents, data }) {
  const appId = functions.config().onesignal?.app_id;
  const apiKey = functions.config().onesignal?.api_key;

  if (!appId || !apiKey) {
    console.log("[communityNotifications] OneSignal not configured. Skipping push send.");
    return;
  }

  const ids = uniqueStrings(playerIds);
  if (!ids.length) {
    console.log("[communityNotifications] No OneSignal player IDs to notify.");
    return;
  }

  const body = JSON.stringify({
    app_id: appId,
    include_player_ids: ids,
    headings,
    contents,
    data,
  });

  await new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: "onesignal.com",
        path: "/api/v1/notifications",
        method: "POST",
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          Authorization: `Basic ${apiKey}`,
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let response = "";
        res.on("data", (chunk) => {
          response += chunk;
        });
        res.on("end", () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            console.log("[communityNotifications] OneSignal success:", response);
            resolve();
          } else {
            console.error("[communityNotifications] OneSignal failed:", res.statusCode, response);
            reject(new Error(`OneSignal request failed with status ${res.statusCode}`));
          }
        });
      }
    );

    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

/**
 * Optional FCM sender.
 * Safe to keep even if you use OneSignal only.
 */
async function sendFcmNotification({ tokens, title, body, data }) {
  const cleanTokens = uniqueStrings(tokens);
  if (!cleanTokens.length) return;

  await admin.messaging().sendEachForMulticast({
    tokens: cleanTokens,
    notification: {
      title,
      body,
    },
    data: Object.fromEntries(
      Object.entries(data || {}).map(([k, v]) => [k, String(v)])
    ),
    apns: {
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  });
}

/**
 * Trigger when a new community message is created.
 */
const onCommunityMessageCreated = functions.firestore
  .document("njangiGroups/{groupId}/communityMessages/{messageId}")
  .onCreate(async (snap, context) => {
    const message = snap.data() || {};
    const { groupId, messageId } = context.params;

    const senderUid = typeof message.senderUid === "string" ? message.senderUid.trim() : "";
    const senderName =
      typeof message.senderName === "string" && message.senderName.trim()
        ? message.senderName.trim()
        : "Someone";

    const groupTitle =
      typeof message.groupTitle === "string" && message.groupTitle.trim()
        ? message.groupTitle.trim()
        : "Community";

    const previewText = buildPreviewText(message);
    const createdAt = message.createdAt || admin.firestore.FieldValue.serverTimestamp();

    if (!senderUid) {
      console.log("[communityNotifications] Missing senderUid. Aborting.");
      return null;
    }

    console.log("[communityNotifications] Processing message", {
      groupId,
      messageId,
      senderUid,
      senderName,
      groupTitle,
      previewText,
    });

    const membersSnap = await db
      .collection("njangiGroups")
      .doc(groupId)
      .collection("members")
      .get();

    if (membersSnap.empty) {
      console.log("[communityNotifications] No members found for group:", groupId);
      return null;
    }

    const recipientUids = [];
    const batch = db.batch();

    membersSnap.forEach((doc) => {
      const memberData = doc.data() || {};
      const memberUidRaw = typeof memberData.uid === "string" ? memberData.uid : doc.id;
      const memberUid = (memberUidRaw || "").trim();

      if (!memberUid || memberUid === senderUid) return;

      recipientUids.push(memberUid);

      const inboxRef = db
        .collection("users")
        .doc(memberUid)
        .collection("communityInbox")
        .doc(groupId);

      batch.set(
        inboxRef,
        {
          groupId,
          groupTitle,
          lastMessageText: previewText,
          lastMessageSenderName: senderName,
          lastMessageAt: createdAt,
          senderUid,
          lastMessageId: messageId,
          unreadCount: admin.firestore.FieldValue.increment(1),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      const membershipRef = db
        .collection("njangiGroups")
        .doc(groupId)
        .collection("members")
        .doc(memberUid);

      batch.set(
        membershipRef,
        {
          unreadCommunityCount: admin.firestore.FieldValue.increment(1),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });

    await batch.commit();

    if (!recipientUids.length) {
      console.log("[communityNotifications] No recipients after excluding sender.");
      return null;
    }

    const userDocs = await Promise.all(
      recipientUids.map((uid) => db.collection("users").doc(uid).get())
    );

    let oneSignalPlayerIds = [];
    let fcmTokens = [];

    userDocs.forEach((doc) => {
      const userData = doc.data() || {};
      const targets = extractPushTargets(userData);
      oneSignalPlayerIds.push(...targets.oneSignalPlayerIds);
      fcmTokens.push(...targets.fcmTokens);
    });

    oneSignalPlayerIds = uniqueStrings(oneSignalPlayerIds);
    fcmTokens = uniqueStrings(fcmTokens);

    const payloadData = {
      type: "community_message",
      screen: "community",
      groupId,
      messageId,
      senderUid,
    };

    const title = groupTitle;
    const body = `${senderName}: ${previewText}`;

    try {
      if (oneSignalPlayerIds.length) {
        await sendOneSignalNotification({
          playerIds: oneSignalPlayerIds,
          headings: { en: title },
          contents: { en: body },
          data: payloadData,
        });
      } else {
        console.log("[communityNotifications] No OneSignal IDs found.");
      }
    } catch (error) {
      console.error("[communityNotifications] OneSignal error:", error);
    }

    try {
      if (fcmTokens.length) {
        await sendFcmNotification({
          tokens: fcmTokens,
          title,
          body,
          data: payloadData,
        });
      } else {
        console.log("[communityNotifications] No FCM tokens found.");
      }
    } catch (error) {
      console.error("[communityNotifications] FCM error:", error);
    }

    return null;
  });

/**
 * Optional callable or helper-safe reset route if you want backend-driven read reset later.
 * You do not strictly need this if iOS writes read state directly.
 */
const markCommunityThreadRead = functions.https.onCall(async (data, context) => {
  if (!context.auth?.uid) {
    throw new functions.https.HttpsError("unauthenticated", "User must be signed in.");
  }

  const uid = context.auth.uid;
  const groupId = typeof data.groupId === "string" ? data.groupId.trim() : "";

  if (!groupId) {
    throw new functions.https.HttpsError("invalid-argument", "groupId is required.");
  }

  const now = admin.firestore.Timestamp.now();

  const batch = db.batch();

  const memberRef = db
    .collection("njangiGroups")
    .doc(groupId)
    .collection("members")
    .doc(uid);

  batch.set(
    memberRef,
    {
      unreadCommunityCount: 0,
      lastReadCommunityMessageAt: now,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  const inboxRef = db
    .collection("users")
    .doc(uid)
    .collection("communityInbox")
    .doc(groupId);

  batch.set(
    inboxRef,
    {
      unreadCount: 0,
      lastReadAt: now,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  await batch.commit();

  return { ok: true, groupId };
});

module.exports = {
  onCommunityMessageCreated,
  markCommunityThreadRead,
};
