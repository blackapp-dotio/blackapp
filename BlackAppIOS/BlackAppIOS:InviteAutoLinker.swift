import Foundation
import FirebaseAuth
import FirebaseFirestore
import UIKit

/// Captures and redeems invite referrals from links like:
/// https://blackapp.io/invite?ref=<inviterUid>
/// blackappios://something?ref=<inviterUid>
///
/// Stores temporarily in UserDefaults and redeems after auth.
/// Uses backend Cloud Function if you wire it later; for now it writes referrer to Firestore
/// (same as your current LoginView implementation pattern).
public enum InviteAutoLinker {

    // MARK: - Storage keys
    private static let kInviterUidKey = "pending_inviter_uid"
    private static let kSavedAtKey    = "pending_invite_saved_at"
    private static let ttlHours: Double = 72 // give users time to install + sign up

    // MARK: - Public API

    /// Call this from .onOpenURL / universal link handlers to cache ref=...
    public static func captureInviterUidFromURL(_ url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let ref = comps.queryItems?.first(where: { $0.name.lowercased() == "ref" })?.value,
              !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let inviter = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        cache(inviterUid: inviter)
        print("🔗 [Invite] cached inviter uid=\(inviter)")
    }

    /// Optional: also capture from clipboard if you still want this UX safety net.
    public static func primeInviteCaptureFromPasteboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // If someone copies a full invite URL, we still capture.
        if let url = URL(string: text) {
            captureInviterUidFromURL(url)
            return
        }
        // Or if they only copied the UID
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeFirebaseUID(trimmed) {
            cache(inviterUid: trimmed)
            print("🔗 [Invite] cached inviter uid from pasteboard=\(trimmed)")
        }
    }

    /// Call this after auth to attach the inviter to the current user (once).
    /// Current behavior: sets users/{uid}.referrer in Firestore if not already set.
    public static func linkInviterIfPresentAfterAuth(completion: ((Bool, String?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else {
            completion?(false, nil); return
        }
        guard let inviter = freshCachedInviterUid() else {
            completion?(false, nil); return
        }
        guard inviter != me else {
            clearCache()
            completion?(false, "Invalid invite (self)"); return
        }

        let fs = Firestore.firestore()
        let meRef = fs.collection("users").document(me)

        meRef.getDocument { snap, err in
            if let err = err {
                completion?(false, "Invite check failed: \(err.localizedDescription)")
                return
            }
            let data = snap?.data() ?? [:]
            if data["referrer"] != nil {
                clearCache()
                completion?(false, "Invite already linked")
                return
            }

            // Minimal: store referrer on user doc.
            // Your backend can later read this and increment inviter stats / dual-write.
            meRef.setData([
                "referrer": inviter,
                "referrerLinkedAt": FieldValue.serverTimestamp()
            ], merge: true) { err in
                if let err = err {
                    completion?(false, "Couldn’t link invite: \(err.localizedDescription)")
                } else {
                    clearCache()
                    completion?(true, "Invite linked 🎉")
                }
            }
        }
    }

    // MARK: - Internals

    private static func cache(inviterUid: String) {
        let ud = UserDefaults.standard
        ud.set(inviterUid, forKey: kInviterUidKey)
        ud.set(Date().timeIntervalSince1970, forKey: kSavedAtKey)
        ud.synchronize()
    }

    private static func freshCachedInviterUid() -> String? {
        let ud = UserDefaults.standard
        guard let inviter = ud.string(forKey: kInviterUidKey), !inviter.isEmpty else { return nil }

        let savedAt = ud.double(forKey: kSavedAtKey)
        guard savedAt > 0 else { return inviter }

        let ageHrs = (Date().timeIntervalSince1970 - savedAt) / 3600.0
        if ageHrs <= ttlHours { return inviter }

        clearCache()
        return nil
    }

    private static func clearCache() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: kInviterUidKey)
        ud.removeObject(forKey: kSavedAtKey)
        ud.synchronize()
    }

    private static func looksLikeFirebaseUID(_ s: String) -> Bool {
        // Rough heuristic: Firebase Auth UIDs are commonly 28 chars, mixed case/digits.
        // We keep it permissive to avoid blocking real UIDs.
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 20 && t.count <= 64 && t.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}
