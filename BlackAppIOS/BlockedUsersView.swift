import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// MARK: - Lightweight shared avatar (local to this file)
struct CachedAvatar: View {
    let urlString: String?
    let displayName: String?
    let size: CGFloat

    init(urlString: String?, displayName: String? = nil, size: CGFloat = 44) {
        self.urlString = urlString
        self.displayName = displayName
        self.size = size
    }

    var body: some View {
        Group {
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure(_):
                        initialsView
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color(.systemGray5))
            ProgressView().scaleEffect(0.8)
        }
    }

    private var initialsView: some View {
        let initials = initials(from: displayName ?? "")
        return ZStack {
            Circle().fill(Color(.systemGray5))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        let first = parts.first?.prefix(1) ?? ""
        let second = parts.dropFirst().first?.prefix(1) ?? ""
        return (first + second).uppercased()
    }
}

// MARK: - Model
struct BlockedEntry: Identifiable {
    let id: String           // = blocked user's uid (doc id)
    let name: String
    let username: String
    let profileImageURL: String?
    let blockedAt: Date?

    init(id: String, data: [String: Any]) {
        self.id = id
        self.name = (data["name"] as? String)
            ?? (data["displayName"] as? String)
            ?? (data["fullName"] as? String)
            ?? ""
        self.username = (data["username"] as? String)
            ?? (data["handle"] as? String)
            ?? ""
        self.profileImageURL = (data["profileImageURL"] as? String)
            ?? (data["photoURL"] as? String)
            ?? (data["avatarUrl"] as? String)
        if let ts = data["blockedAt"] as? Timestamp {
            self.blockedAt = ts.dateValue()
        } else {
            self.blockedAt = nil
        }
    }
}

// MARK: - View
struct BlockedUsersView: View {
    @State private var entries: [BlockedEntry] = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var unblocking: Set<String> = []

    var body: some View {
        List {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading blocked users…")
                }
            } else if let error = error {
                Text(error).foregroundColor(.red)
            } else if entries.isEmpty {
                Text("You haven’t blocked anyone.").foregroundColor(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        CachedAvatar(urlString: entry.profileImageURL, displayName: entry.name, size: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name.isEmpty ? "Unknown user" : entry.name)
                                .font(.headline)
                            if !entry.username.isEmpty {
                                Text("@\(entry.username)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            if let when = entry.blockedAt {
                                Text("Blocked \(relative(when))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        if unblocking.contains(entry.id) {
                            ProgressView().scaleEffect(0.9)
                        } else {
                            Button(role: .destructive) {
                                Task { await unblock(entry.id) }
                            } label: {
                                Text("Unblock")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Blocked")
        .onAppear(perform: loadBlocked)
        .refreshable { await reloadBlocked() }
    }

    // MARK: - Data
    private func loadBlocked() {
        Task { await reloadBlocked() }
    }

    private func reloadBlocked() async {
        await MainActor.run {
            isLoading = true
            error = nil
            entries.removeAll()
        }

        guard let me = Auth.auth().currentUser?.uid else {
            await MainActor.run {
                isLoading = false
                error = "Not signed in."
            }
            return
        }

        do {
            // Read all documents under: blocks/{me}/blocked
            let snap = try await Firestore.firestore()
                .collection("blocks")
                .document(me)
                .collection("blocked")
                .order(by: "blockedAt", descending: true)
                .getDocuments()

            var list: [BlockedEntry] = []
            for doc in snap.documents {
                var data = doc.data()
                // Optional enrichment: fetch user display info (if not mirrored)
                if (data["name"] as? String) == nil || (data["username"] as? String) == nil {
                    let udata = try? await Firestore.firestore().collection("users").document(doc.documentID).getDocument().data()
                    if let u = udata {
                        data["name"] = data["name"] ?? u["name"]
                        data["username"] = data["username"] ?? u["username"]
                        data["profileImageURL"] = data["profileImageURL"] ?? u["profileImageURL"]
                    }
                }
                list.append(BlockedEntry(id: doc.documentID, data: data))
            }

            await MainActor.run {
                self.entries = list
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    // MARK: - Actions
    private func unblock(_ userId: String) async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        await MainActor.run { unblocking.insert(userId) }
        defer { Task { await MainActor.run { unblocking.remove(userId) } } }

        do {
            try await Firestore.firestore()
                .collection("blocks")
                .document(me)
                .collection("blocked")
                .document(userId)
                .delete()

            // Optimistic UI update
            await MainActor.run {
                entries.removeAll { $0.id == userId }
            }
        } catch {
            print("❌ Unblock failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Utils
    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview (optional)
struct BlockedUsersView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView { BlockedUsersView() }
    }
}
