import SwiftUI
import FirebaseAuth
import FirebaseDatabase

struct SupportModalView: View {
    @Environment(\.dismiss) var dismiss
    @State private var message = ""
    @State private var isSending = false
    @State private var showConfirmation = false

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Send a message to our support team. We’ll get back to you as soon as possible.")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                TextEditor(text: $message)
                    .frame(minHeight: 150)
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)

                Button(action: sendSupportMessage) {
                    HStack {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "paperplane.fill")
                            Text("Send Message")
                        }
                    }
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                .disabled(isSending || message.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Support")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .alert(isPresented: $showConfirmation) {
                Alert(
                    title: Text("✅ Message Sent"),
                    message: Text("Your message has been submitted. We’ll be in touch shortly."),
                    dismissButton: .default(Text("OK")) {
                        dismiss()
                    }
                )
            }
        }
    }

    private func sendSupportMessage() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        isSending = true
        let ref = Database.database().reference()
        let supportRef = ref.child("supportMessages").childByAutoId()

        let messageData: [String: Any] = [
            "userId": userId,
            "message": message,
            "timestamp": Date().timeIntervalSince1970
        ]

        supportRef.setValue(messageData) { error, _ in
            isSending = false
            if error == nil {
                message = ""
                showConfirmation = true
            }
        }
    }
}
