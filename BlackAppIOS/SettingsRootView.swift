import SwiftUI
import FirebaseAuth

struct SettingsRootView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoggingOut = false

    var body: some View {
        List {
            Section(header: Text("Account")) {
                NavigationLink {
                    BlockedUsersView()
                } label: {
                    Label("Blocked Users", systemImage: "hand.raised.fill")
                }

                NavigationLink {
                    DeleteAccountView()
                } label: {
                    Label("Delete Account", systemImage: "person.crop.circle.badge.minus")
                }
                .foregroundColor(.red)
            }

            Section(header: Text("Support")) {
                NavigationLink {
                    SupportLinksView()
                } label: {
                    Label("Contact & Legal", systemImage: "questionmark.circle")
                }
            }

            Section {
                Button(role: .destructive) {
                    isLoggingOut = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Settings")
        .alert("Sign out?", isPresented: $isLoggingOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                try? Auth.auth().signOut()
                dismiss()
            }
        }
    }
}
