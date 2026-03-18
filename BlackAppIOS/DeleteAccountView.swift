import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseDatabase
import UIKit

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
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Deleting… please wait")
                            .foregroundColor(.secondary)
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
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - Confirm UI (no UIApplication extension; avoids redeclare collisions)
    private func confirm() {
        presentDeleteConfirmAlert(
            title: "Delete Account?",
            message: "This will permanently delete your BlackApp account and related data.",
            confirmTitle: "Delete"
        ) {
            Task { await deleteCascade() }
        }
    }

    private func presentDeleteConfirmAlert(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { _ in
            onConfirm()
        })

        DispatchQueue.main.async {
            guard let top = topMostViewController() else { return }
            top.present(alert, animated: true)
        }
    }

    private func topMostViewController() -> UIViewController? {
        // Key-window lookup compatible with multi-scene apps
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })

        guard var top = keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // MARK: - Deletion Cascade
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
        try await Firestore.firestore().collection("users").document(uid).setData([
            "fcmToken": FieldValue.delete(),
            "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    private func deleteUserDocuments(uid: String) async throws {
        // Firestore: users/{uid}
        try await Firestore.firestore().collection("users").document(uid).delete()

        // RTDB: users/{uid} (adjust to your schema)
        let rtdb = Database.database().reference()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            rtdb.child("users").child(uid).removeValue { err, _ in
                if let err = err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume(returning: ()) // ✅ must return Void
                }
            }
        }

        // TODO: If you have other per-user paths (posts, purchases, chats, etc.),
        // delete them here or move this fan-out into a Cloud Function.
    }
}
