// AccountDeletionView.swift
import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseDatabase

struct AccountDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Delete Account")
                    .font(.title2).bold().foregroundColor(.white)

                Text("This will permanently delete your account and content. This action cannot be undone.")
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                SecureField("Confirm your password", text: $password)
                    .textContentType(.password)
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                    .foregroundColor(.white)
                    .padding(.horizontal)

                if let error { Text(error).foregroundColor(.red).font(.footnote) }

                Button(role: .destructive) {
                    Task { await deleteFlow() }
                } label: {
                    if working { ProgressView().tint(.white) }
                    else { Text("Delete My Account") }
                }
                .disabled(working || password.isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Spacer()
            }
            .padding(.top, 24)
            .background(Color.black.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func deleteFlow() async {
        guard let user = Auth.auth().currentUser, let email = user.email else {
            await MainActor.run { error = "No authenticated user."; working = false }
            return
        }
        await MainActor.run { working = true; error = nil }

        do {
            // 1) Reauthenticate with email/password
            let cred = EmailAuthProvider.credential(withEmail: email, password: password)
            try await user.reauthenticate(with: cred)

            // 2) Client-side cleanup (safe minimum); server can finish the rest
            try await clientCleanup(uid: user.uid)

            // 3) Auth deletion
            try await user.delete()

            // 4) Optional: Create a deletion request doc so backend can finish deep cleanup
            let req = Firestore.firestore().collection("deletionRequests").document(user.uid)
            try? await req.setData([
                "uid": user.uid,
                "createdAt": FieldValue.serverTimestamp(),
                "status": "queued"
            ], merge: true)

            await MainActor.run {
                working = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.working = false
            }
        }
    }

    private func clientCleanup(uid: String) async throws {
        let db = Firestore.firestore()

        // users/{uid}
        try? await db.collection("users").document(uid).delete()

        // blocks/{uid}/blocked/*
        let bSnap = try? await db.collection("blocks").document(uid).collection("blocked").getDocuments()
        if let docs = bSnap?.documents {
            let batch = db.batch()
            for d in docs { batch.deleteDocument(d.reference) }
            try? await batch.commit()
        }
        try? await db.collection("blocks").document(uid).delete()

        // RTDB mirrors
        let root = Database.database().reference()
        await withCheckedContinuation { cont in
            root.child("blocks").child(uid).removeValue { _, _ in cont.resume() }
        }
    }
}
