import Foundation
import FirebaseFunctions
import FirebaseAuth

enum ReferralManager {
    private static var functions = Functions.functions()

    static func consumePendingReferralIfAny(currentUserId: String) {
        guard let inviterId = UserDefaults.standard.string(forKey: "pendingReferrerUid"),
              !inviterId.isEmpty,
              inviterId != currentUserId else {
            return
        }

        // Clear before call to avoid double fires on app relaunches
        UserDefaults.standard.removeObject(forKey: "pendingReferrerUid")

        let payload: [String: Any] = [
            "inviterId": inviterId,
            "inviteeId": currentUserId
        ]

        functions.httpsCallable("acceptInvite").call(payload) { result, error in
            if let error = error {
                print("⚠️ acceptInvite failed: \(error.localizedDescription)")
                return
            }
            if let data = result?.data as? [String: Any] {
                print("✅ acceptInvite ok:", data)
            }
        }
    }
}
