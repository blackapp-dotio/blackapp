// SocialPlatformSyncView.swift
// Modular sync manager for social platform handles

import SwiftUI
import Firebase

struct SyncedAccount: Identifiable {
    let id = UUID()
    let platform: String
    var handle: String?
    var isLinked: Bool { handle != nil && !handle!.isEmpty }
    var iconName: String {
        switch platform {
        case "Instagram": return "camera.circle.fill"
        case "Twitter": return "bird.fill"
        case "Facebook": return "f.circle.fill"
        case "TikTok": return "music.note"
        case "YouTube": return "play.rectangle.fill"
        default: return "questionmark.circle.fill"
        }
    }
}

struct SocialPlatformSyncView: View {
    @Binding var syncedAccounts: [SyncedAccount]
    var userId: String

    @State private var selectedPlatform: String? = nil
    @State private var handleInput: String = ""
    @State private var showInputPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected Platforms")
                .font(.headline)
            HStack(spacing: 16) {
                ForEach(0..<syncedAccounts.count, id: \.self) { index in
                    let account = syncedAccounts[index]
                    Button(action: {
                        selectedPlatform = account.platform
                        handleInput = account.handle ?? ""
                        showInputPrompt = true
                    }) {
                        Image(systemName: account.iconName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .foregroundColor(account.isLinked ? .green : .gray)
                            .padding(10)
                            .background(Circle().fill(Color.black.opacity(0.2)))
                    }
                }
            }
        }
        .padding(.vertical)
        .sheet(isPresented: $showInputPrompt) {
            VStack(spacing: 20) {
                Text("Enter your \(selectedPlatform ?? "") handle")
                    .font(.title3)
                    .padding(.top)

                TextField("@yourHandle", text: $handleInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                Button("Save") {
                    if let selected = selectedPlatform,
                       let index = syncedAccounts.firstIndex(where: { $0.platform == selected }) {
                        syncedAccounts[index].handle = handleInput
                        saveToFirebase(platform: selected, handle: handleInput)
                    }
                    showInputPrompt = false
                }
                .padding()
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    showInputPrompt = false
                }
                .foregroundColor(.red)
                .padding(.bottom)
            }
            .presentationDetents([.medium])
        }
    }

    private func saveToFirebase(platform: String, handle: String) {
        let ref = Database.database().reference()
        ref.child("users/\(userId)/syncedPlatforms/\(platform)").setValue([
            "linked": true,
            "handle": handle
        ]) { error, _ in
            if let error = error {
                print("❌ Error saving handle: \(error.localizedDescription)")
            } else {
                print("✅ \(platform) handle saved: \(handle)")
            }
        }
    }
}
