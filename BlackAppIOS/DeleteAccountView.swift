import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseDatabase

struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isDeleting = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete your account")
                        .font(.headline)
                    Text("This will permanently remove your profile and related data. This action cannot be undone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                Button(role: .destructive) {
                    confirm()
                } label: {
                   Label("Delete Account", systemImage: "trash")
                }
                .disabled(isDeleting)
            }

            if isDeleting {
                Section {
                    HStack {
                        ProgressView()
                        Text("Deleting… please wait")
                    }
                }
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Account Failed", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func confirm() {
        let alert = UIAlertController(
            title: "Delete Account?",
            message: "This will permanently delete your BlackApp account and related data.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { _ in
            Task { await deleteCascade() }
        }))
        UIApplication.shared.topMostController?.present(alert, animated: true)
    }

    @MainActor
    private func deleteCascade() async {
        guard let user = Auth.auth().currentUser else { return }
        isDeleting = true
        defer { isDeleting = false }

        let uid = user.uid
        do {
            try await clearPushToken(uid: uid)
            try await deleteUserDocuments(uid: uid)

            // Delete Auth user (may require recent login)
            try await user.delete()

            // Local sign out (ignore error)
            try? Auth.auth().signOut()

            // Close when done
            dismiss()
        } catch {
            let ns = error as NSError
            if ns.code == AuthErrorCode.requiresRecentLogin.rawValue {
                errorText = "For your security, please re-authenticate (log out and back in) and try deleting again."
            } else {
                errorText = ns.localizedDescription
            }
        }
    }

    private func clearPushToken(uid: String) async throws {
        try await Firestore.firestore().collection("users").document(uid)
            .setData([
                "fcmToken": FieldValue.delete(),
                "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }

    private func deleteUserDocuments(uid: String) async throws {
        // Firestore: users/{uid}
        try await Firestore.firestore().collection("users").document(uid).delete()

        // RTDB: users/{uid}  (adjust to your schema)
        let rtdb = Database.database().reference()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            rtdb.child("users").child(uid).removeValue { err, _ in
                if let err = err { cont.resume(throwing: err) }
                else { cont.resume(returning: ()) } // ✅ must return Void
            }
        }

        // TODO: If you have other per-user paths (e.g., purchases, posts, chats),
        // add their deletions here or move to a Cloud Function for fan-out.
    }
}

private extension UIApplication {
    var keyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    var topMostController: UIViewController? {
        guard var top = keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
