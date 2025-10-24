// SettingsView.swift
import SwiftUI
import FirebaseAuth

struct SettingsView: View {
    @State private var showBlocks = false
    @State private var showDelete = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Account")) {
                    Button {
                        showBlocks = true
                    } label: {
                        Label("Manage Blocked Users", systemImage: "hand.raised")
                    }

                    Button(role: .destructive) {
                        showDelete = true
                    } label: {
                        Label("Delete My Account", systemImage: "trash")
                    }
                }

                Section(header: Text("Support")) {
                    Button {
                        if let url = URL(string: "mailto:support@blackapp.io?subject=BlackApp%20Support") {
                            openURL(url)
                        }
                    } label: {
                        Label("Contact Support", systemImage: "envelope")
                    }

                    Link(destination: URL(string: "https://blackapp.io/terms")!) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }
                  
                    Link(destination: URL(string: "https://blackapp.io/privacy")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }

                Section {
                    Button {
                        try? Auth.auth().signOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showBlocks) { BlockedUsersView() }
            .sheet(isPresented: $showDelete) { AccountDeletionView() }
        }
        .preferredColorScheme(.dark)
    }
}
