import SwiftUI
import Firebase
import FirebaseAuth

struct EditAccountView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var displayName = ""
    @State private var isSaving = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Edit Profile")
                    .font(.title)
                    .bold()

                TextField("Display Name", text: $displayName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button(action: updateProfile) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save Changes")
                            .bold()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)

                Spacer()
            }
            .padding()
            .onAppear(perform: loadUserData)
            .preferredColorScheme(.dark)
        }
    }

    func loadUserData() {
        if let user = Auth.auth().currentUser {
            displayName = user.displayName ?? ""
        }
    }

    func updateProfile() {
        guard !displayName.isEmpty, let user = Auth.auth().currentUser else { return }
        isSaving = true

        let changeRequest = user.createProfileChangeRequest()
        changeRequest.displayName = displayName
        changeRequest.commitChanges { _ in
            isSaving = false
            presentationMode.wrappedValue.dismiss()
        }
    }
}
