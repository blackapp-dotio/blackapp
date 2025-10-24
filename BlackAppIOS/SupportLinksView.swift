import SwiftUI

struct SupportLinksView: View {
    var body: some View {
        List {
            Section(header: Text("Help & Support")) {
                Link(destination: URL(string: "https://blackappios.web.app/support.html")!) {
                    Label("Support Center", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "mailto:support@blackapp.io")!) {
                    Label("Email Support", systemImage: "envelope")
                }
            }

            Section(header: Text("Policies")) {
                Link(destination: URL(string: "https://blackappios.web.app/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://blackappios.web.app/terms.html")!) {
                    Label("Terms of Service", systemImage: "doc.plaintext")
                }
            }

            Section(header: Text("Community Safety")) {
                Button {
                    NotificationCenter.default.post(name: .openBlockedUsers, object: nil)
                } label: {
                    Label("Manage Blocked Users", systemImage: "eye.slash")
                }
            }
        }
        .navigationTitle("Support & Legal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/*extension Notification.Name {
    static let openBlockedUsers = Notification.Name("openBlockedUsers")
}
*/
