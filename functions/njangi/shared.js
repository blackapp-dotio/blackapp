// functions/njangi/shared.js
// Shared helpers for Njangi backend logic

const admin = require("firebase-admin");
const functions = require("firebase-functions");

const db = admin.firestore();

/**
 * Ensure request is authenticated.
 */
function requireAuth(context) {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "You must be signed in to perform this action."
    );
  }
  return context.auth.uid;
}

/**
 * Load Njangi group doc or throw not-found.
 */
async function getNjangiGroupOrThrow(groupId) {
  if (!groupId || typeof groupId !== "string") {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "A valid groupId is required."
    );
  }
  const ref = db.collection("njangiGroups").doc(groupId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new functions.https.HttpsError(
      "not-found",
      "Njangi group not found."
    );
  }
  return { ref, data: snap.data(), id: snap.id };
}

/**
 * Load membership doc or null.
 */
async function getMembership(groupId, uid) {
  const ref = db
    .collection("njangiGroups")
    .doc(groupId)
    .collection("members")
    .doc(uid);
  const snap = await ref.get();
  if (!snap.exists) return null;
  return { ref, data: snap.data(), id: snap.id };
}

/**
 * Require that caller is an active member.
 */
async function requireMember(groupId, uid) {
  const membership = await getMembership(groupId, uid);
  if (!membership) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "You are not a member of this group."
    );
  }
  const status = (membership.data.status || "").toLowerCase();
  if (status !== "active" && status !== "owner" && status !== "admin") {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Your membership is not active."
    );
  }
  return membership;
}

/**
 * Require caller to be owner or admin.
 */
async function requireAdminOrOwner(group, uid) {
  const ownerId = group.data.ownerId;
  if (ownerId && ownerId === uid) return true;

  const membership = await getMembership(group.id, uid);
  if (!membership) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "You are not an admin or owner of this group."
    );
  }
  const role = (membership.data.role || "").toLowerCase();
  if (role !== "admin" && role !== "owner") {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Admin or owner privileges are required."
    );
  }
  return true;
}

/**
 * Ensure group is not in setup-only locked state for the given action.
 * We still allow contributions + withdrawals when status=active.
 */
function ensureGroupActiveOrSetup(group, actionLabel) {
  const status = (group.data.status || "").toLowerCase();
  if (status !== "active" && status !== "setup") {
    throw new functions.https.HttpsError(
      "failed-precondition",
      `Group is not in a valid state for ${actionLabel || "this action"}.`
    );
  }
}

/**
 * Convert a numeric amount to integer cents, with basic checks.
 */
function toCents(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n) || n <= 0) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Amount must be a positive number."
    );
  }
  return Math.round(n * 100);
}

/**
 * Fixed 5% platform fee (withdrawals only).
 * Returns an integer cents value.
 */
function computePlatformFeeCents(amountCents) {
  if (!Number.isInteger(amountCents) || amountCents <= 0) {
    throw new Error("Invalid amountCents for fee.");
  }
  // Keep consistent rounding (floor to be safe)
  return Math.floor(amountCents * 0.05);
}

/**
 * Safe now() server timestamp + millis.
 */
function now() {
  return admin.firestore.Timestamp.now();
}

module.exports = {
  db,
  functions,
  requireAuth,
  getNjangiGroupOrThrow,
  getMembership,
  requireMember,
  requireAdminOrOwner,
  ensureGroupActiveOrSetup,
  toCents,
  computePlatformFeeCents,
  now,
};

