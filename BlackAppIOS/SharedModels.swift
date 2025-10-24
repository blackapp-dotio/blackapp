import SwiftUI
import Foundation


    
    struct ChatMessage: Identifiable {
        var id: String
        var text: String?
        var mediaURL: String?
        var type: String
        var isSender: Bool
        var documentId: String?
        var edited: Bool
        var likes: [String]
        var comments: [[String: String]]
        var reposts: [String]
        var senderName: String
    }
    
    
    // User Profile for Chats
    struct ChatUserProfile: Identifiable, Codable {
        let id: String
        let name: String
        let username: String
        var profileImageURL: String? // ✅ Add this
        var bio: String? = ""
    }
    
    
    
/*    // Chat Bubble Shape
struct WaterDropShape: Shape {
    var isSender: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 20)
        let tailSize: CGFloat = 10

        if isSender {
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - 20))
            path.addLine(to: CGPoint(x: rect.maxX + tailSize, y: rect.maxY - 10))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 20))
            path.addLine(to: CGPoint(x: rect.minX - tailSize, y: rect.maxY - 10))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        return path
    }
} */
// MARK: - Support Message Model
struct SupportMessage: Identifiable {
    let id: String
        let userId: String
        let text: String
        let timestamp: TimeInterval
        let name: String
        let email: String
        var status: String? = nil
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
/*
import SwiftUI
import FirebaseAuth

struct EmailVerificationBanner: View {
    @State private var isVerified: Bool = Auth.auth().currentUser?.isEmailVerified ?? true
    @State private var sending = false
    @State private var info: String?

    var body: some View {
        Group {
            if !isVerified {
                VStack(spacing: 8) {
                    HStack(alignment: .center) {
                        Image(systemName: "envelope.badge")
                        Text("Please verify your email to secure your account.")
                            .font(.subheadline)
                        Spacer()
                        Button("Resend") { resend() }
                            .disabled(sending)
                        Button("I’ve verified") { reload() }
                    }
                    if let info { Text(info).font(.caption).foregroundColor(.gray) }
                }
                .padding(12)
                .background(Color.yellow.opacity(0.15))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        Auth.auth().currentUser?.reload { _ in
            isVerified = Auth.auth().currentUser?.isEmailVerified ?? false
        }
    }

    private func resend() {
        guard let user = Auth.auth().currentUser else { return }
        sending = true

        Auth.auth().useAppLanguage() // optional localization
        let acs = makeActionCodeSettings()

        user.sendEmailVerification(with: acs) { error in
            sending = false
            if let error = error {
                info = "Failed to send: \(error.localizedDescription)"
                print("❌ resend verification: \(error.localizedDescription)")
            } else {
                info = "Verification email sent."
                print("✅ resend verification sent to \(user.email ?? "(no email)")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { info = nil }
        }
    }

    // Keep this here so the banner is standalone
    private func makeActionCodeSettings() -> ActionCodeSettings {
        let acs = ActionCodeSettings()
        acs.url = URL(string: "https://blackappios.web.app/verify") // your Hosting domain
        acs.handleCodeInApp = false
        if let bundleId = Bundle.main.bundleIdentifier {
            acs.setIOSBundleID(bundleId)
        }
        // If you use Firebase Dynamic Links, you can set:
        // acs.dynamicLinkDomain = "blackappios.page.link"
        return acs
    }
} */
// BlockMirror.swift
import Foundation
import FirebaseAuth
import FirebaseDatabase

enum BlockMirror {
    /// Mirror a block to RTDB: blocks/{me}/blocked/{target}
    static func mirrorBlock(targetUid: String, completion: ((Error?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else {
            completion?(NSError(domain: "BlockMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in"]))
            return
        }
        let r = Database.database().reference()
            .child("blocks").child(me).child("blocked").child(targetUid)
        let payload: [String: Any] = [
            "userId": targetUid,
            "blockedAt": ServerValue.timestamp()
        ]
        r.setValue(payload) { error, _ in completion?(error) }
    }

    /// Remove a block mirror from RTDB
    static func mirrorUnblock(targetUid: String, completion: ((Error?) -> Void)? = nil) {
        guard let me = Auth.auth().currentUser?.uid else {
            completion?(NSError(domain: "BlockMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in"]))
            return
        }
        let r = Database.database().reference()
            .child("blocks").child(me).child("blocked").child(targetUid)
        r.removeValue { error, _ in completion?(error) }
    }
}
