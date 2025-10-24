import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct TermsGateView: View {
    var onAccepted: () -> Void

    @State private var agreed = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Terms & Community Guidelines")
                .font(.title2).bold()
                .foregroundColor(.white)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Zero tolerance for illegal, hateful, harassing, or sexual content. We remove violating content and may suspend repeat offenders within 24 hours.")
                    Link("Read full Terms", destination: URL(string: "https://blackapp.io/terms")!)
                    Link("Community Guidelines", destination: URL(string: "https://blackapp.io/community")!)
                }
                .foregroundColor(.white.opacity(0.9))
            }
            .frame(maxHeight: 220)

            Toggle(isOn: $agreed) {
                Text("I agree to the Terms & Community Guidelines")
                    .foregroundColor(.white)
            }
            .toggleStyle(SwitchToggleStyle(tint: .white))

            if let error { Text(error).foregroundColor(.red).font(.footnote) }

            Button {
                Task { await saveAndContinue() }
            } label: {
                HStack {
                    if isSaving { ProgressView().tint(.black) }
                    Text("Agree & Continue")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding().background(agreed ? Color.white : Color.gray)
                .foregroundColor(.black).cornerRadius(10)
            }
            .disabled(!agreed || isSaving)
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
    }

    private func saveAndContinue() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isSaving = true; error = nil
        do {
            try await Firestore.firestore().collection("users").document(uid)
                .setData(["acceptedTermsAt": FieldValue.serverTimestamp()], merge: true)
            onAccepted()
        } catch {
            self.error = "Could not save. Check your connection and try again."
        }
        isSaving = false
    }
}
