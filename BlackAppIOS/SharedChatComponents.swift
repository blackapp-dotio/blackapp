//
//  SharedChatComponents.swift
//  BlackAppIOS
//
//  Complete, merged, and ready-to-use
//

import Foundation
import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import UniformTypeIdentifiers
import AVKit
import PhotosUI

// ======================================================
// MARK: - Data Models (Group & Contact helpers)
// ======================================================

struct GroupChat: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var description: String?
    var coverImageURL: String?
    var ownerId: String
    var members: [String]
    var adminIds: [String]

    static func from(_ doc: DocumentSnapshot) -> GroupChat? {
        let data = doc.data() ?? [:]
        guard let name = data["name"] as? String,
              let members = data["members"] as? [String],
              let ownerId = data["ownerId"] as? String else { return nil }

        return GroupChat(
            id: doc.documentID,
            name: name,
            description: data["description"] as? String,
            coverImageURL: data["coverImageURL"] as? String,
            ownerId: ownerId,
            members: members,
            adminIds: data["adminIds"] as? [String] ?? []
        )
    }
}

/// Lightweight contact projection for the chat list (joined with user profile)
struct ChatContact: Identifiable {
    let id: String            // other user's uid
    let name: String
    let username: String?
    let profileImageURL: String?
    var status: String        // "active" | "blocked" | "pending"
    var accepted: Bool
    var lastMessageAt: Date?
    var unreadCount: Int
}

// Utilities
enum ChatUtils {
    static func chatId(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }
}

// ======================================================
// MARK: - Top-level ChatTabView
// ======================================================

struct ChatTabView: View {
    @State private var isShowingDirectChats = true
    @State private var showCreateGroup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TopToolbarView(onLogoTap: {}, onSearchTap: {})

                Picker("Chat Type", selection: $isShowingDirectChats) {
                    Text("Direct").tag(true)
                    Text("Groups").tag(false)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()

                if isShowingDirectChats {
                    DirectChatListView()
                } else {
                    GroupChatListView(showCreateGroup: $showCreateGroup)
                }
            }
            .sheet(isPresented: $showCreateGroup) {
                CreateGroupView()
            }
            .onAppear {
                print("💬 ChatTabView appeared. Ensuring FCM token sync...")
                _ = TokenSyncMonitor.shared
            }
            .preferredColorScheme(.dark)
            .background(Color.black.ignoresSafeArea())
        }
    }
}

// ======================================================
// MARK: - DirectChatListView (contacts + unread + block/unblock)
// ======================================================

struct DirectChatListView: View {
    @State private var users: [ChatUserProfile] = []            // All other users (for compose/search)
    @State private var selectedRecipient: ChatUserProfile? = nil
    @State private var lastMessages: [String: String] = [:]     // userId -> preview text
    @State private var showUserPicker = false
    @State private var searchText: String = ""
    @State private var unreadChats: Set<String> = []            // userIds with unread
    @State private var contacts: [ChatContact] = []             // primary source for the list
    @State private var isLoadingContacts = false

    @ObservedObject var router = NotificationRouter.shared

    var body: some View {
        VStack {
            // 🔍 Search Bar (filters the chat list by contact display name)
            TextField("Search chats...", text: $searchText)
                .padding(10)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
                .foregroundColor(.white)
                .padding(.horizontal)

            // 📋 Chat list from contacts (unread-first, then recent)
            List(chatRows) { row in
                ChatUserRow(
                    user: ChatUserProfile(id: row.id, name: row.name, username: row.username ?? "", profileImageURL: row.profileImageURL),
                    preview: lastMessages[row.id],
                    isUnread: row.unreadCount > 0 || unreadChats.contains(row.id),
                    isHighlighted: row.id == router.selectedChatUser?.id,
                    onTap: {
                        // Pending chats (search-origin) require acceptance first
                        if row.status == "pending" && !row.accepted {
                            presentAcceptPrompt(otherUid: row.id)
                            return
                        }
                        selectedRecipient = ChatUserProfile(id: row.id, name: row.name, username: row.username ?? "", profileImageURL: row.profileImageURL)
                        router.selectedChatUser = nil
                    }
                )
                .contextMenu {
                    if row.status == "blocked" {
                        Button("Unblock") { unblockContact(row.id) }
                    } else {
                        Button("Block") { blockContact(row.id) }
                    }
                }
            }
            .id(router.selectedChatUser?.id ?? UUID().uuidString) // force refresh if routed
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)

            // Compose button → pick a user to start a chat (seeds pending request)
            HStack {
                Spacer()
                Button {
                    showUserPicker = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.blue.opacity(0.8))
                        .clipShape(Circle())
                }
                .padding(.trailing, 16)
            }

            // Hidden navigation to the room
            NavigationLink(
                destination: selectedRecipient.map { DirectChatRoomView(recipient: $0) },
                isActive: Binding<Bool>(
                    get: { selectedRecipient != nil },
                    set: { if !$0 { selectedRecipient = nil } }
                )
            ) { EmptyView() }
            .hidden()
        }
        .onAppear {
            fetchUsers()      // for compose picker
            loadContacts()    // primary chat list
        }
        .sheet(isPresented: $showUserPicker) {
            UserPickerView { selectedUser in
                print("👤 Picked user: \(selectedUser.name)")
                seedPendingIfNeeded(otherUid: selectedUser.id)  // creates pending contact both sides
                self.selectedRecipient = selectedUser
            }
        }
        .navigationTitle("Chats")
        .background(Color.black)
    }

    // Derive & sort the rows we show
    var chatRows: [ChatContact] {
        var base = contacts
        if !searchText.isEmpty {
            base = base.filter { $0.name.lowercased().contains(searchText.lowercased()) }
        }
        // hide blocked unless explicitly searched by name
        if searchText.isEmpty {
            base = base.filter { $0.status != "blocked" }
        }
        // Unread first, then most recent by lastMessageAt
        return base.sorted { a, b in
            if a.unreadCount > 0 && b.unreadCount == 0 { return true }
            if a.unreadCount == 0 && b.unreadCount > 0 { return false }
            let ad = a.lastMessageAt ?? .distantPast
            let bd = b.lastMessageAt ?? .distantPast
            return ad > bd
        }
    }

    // --------------------------------------------------
    // MARK: Data loading
    // --------------------------------------------------

    /// Loads all other users for the compose sheet (unchanged behavior)
    func fetchUsers() {
        guard let currentUid = Auth.auth().currentUser?.uid else {
            print("❌ No current user UID found.")
            return
        }
        Firestore.firestore().collection("users").getDocuments { snapshot, error in
            if let error = error {
                print("❌ Error fetching users: \(error.localizedDescription)")
                return
            }
            users = snapshot?.documents.compactMap { doc in
                let data = doc.data()
                let id = doc.documentID
                guard id != currentUid else { return nil }
                guard let name = data["name"] as? String else { return nil }
                let username = data["username"] as? String ?? ""
                let profileImageURL = data["profileImageURL"] as? String
                return ChatUserProfile(id: id, name: name, username: username, profileImageURL: profileImageURL)
            } ?? []

            print("✅ DirectChatListView loaded \(users.count) users.")
            // 👇 Critical: also pull last-message info for ALL users (stable behavior)
            users.forEach { user in
                self.fetchLastMessage(with: user.id)
            }
        }
    }


    /// Loads contact documents that drive the chat list
    func loadContacts() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        isLoadingContacts = true

        Firestore.firestore()
            .collection("users").document(currentUid)
            .collection("contacts")
            .getDocuments { snap, err in
                self.isLoadingContacts = false
                if let err = err {
                    print("❌ contacts error: \(err.localizedDescription)")
                    return
                }
                let docs = snap?.documents ?? []
                var loaded: [ChatContact] = []
                let group = DispatchGroup()

                for d in docs {
                    let otherId = d.documentID
                    let data = d.data()
                    let status = (data["status"] as? String) ?? "active"
                    let accepted = (data["accepted"] as? Bool) ?? (status == "active")
                    let lastMessageAt = (data["lastMessageAt"] as? Timestamp)?.dateValue()
                    let unreadCount = (data["unreadCount"] as? Int) ?? 0

                    group.enter()
                    Firestore.firestore().collection("users").document(otherId).getDocument { userDoc, _ in
                        let udata = userDoc?.data() ?? [:]
                        let name = (udata["name"] as? String) ?? "Unknown"
                        let username = udata["username"] as? String
                        let profileImageURL = udata["profileImageURL"] as? String

                        loaded.append(ChatContact(
                            id: otherId,
                            name: name,
                            username: username,
                            profileImageURL: profileImageURL,
                            status: status,
                            accepted: accepted,
                            lastMessageAt: lastMessageAt,
                            unreadCount: unreadCount
                        ))
                        group.leave()
                    }
                }

                group.notify(queue: .main) {
                    self.contacts = loaded
                    // Refresh last message previews & badges for accuracy
                    loaded.forEach { self.fetchLastMessage(with: $0.id) }
                }
            }
    }

    /// Fetches last message preview + unread state and mirrors lastMessageAt/unreadCount into contact doc
    func fetchLastMessage(with userId: String) {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        let chatId = ChatUtils.chatId(currentUid, userId)
        let messagesRef = Firestore.firestore().collection("directChats").document(chatId)

        messagesRef.collection("messages")
            .order(by: "timestamp", descending: true)
            .limit(to: 1)
            .getDocuments { snapshot, error in
                guard let doc = snapshot?.documents.first else { return } // no messages yet
                let data = doc.data()
                let preview = data["text"] as? String ?? ""
                let messageTimestamp = (data["timestamp"] as? Timestamp)?.dateValue() ?? Date.distantPast
                self.lastMessages[userId] = preview

                messagesRef.collection("readStatus").document(currentUid).getDocument { readSnap, _ in
                    let lastSeen = (readSnap?.data()?["lastSeen"] as? Timestamp)?.dateValue() ?? Date.distantPast
                    let isUnread = messageTimestamp > lastSeen

                    if isUnread { self.unreadChats.insert(userId) } else { self.unreadChats.remove(userId) }

                    // If this peer is NOT already in contacts array, promote them (UI) and backfill a contact doc.
                    if self.contacts.firstIndex(where: { $0.id == userId }) == nil {
                        // Look up display fields from loaded users (stable-style)
                        let fallback = ChatUserProfile(id: userId, name: "Unknown", username: "", profileImageURL: nil)
                        let u = self.users.first(where: { $0.id == userId }) ?? fallback

                        self.contacts.append(
                            ChatContact(
                                id: u.id,
                                name: u.name,
                                username: u.username,
                                profileImageURL: u.profileImageURL,
                                status: "active",                 // treat as active for UI if history exists
                                accepted: true,
                                lastMessageAt: messageTimestamp,
                                unreadCount: isUnread ? 1 : 0
                            )
                        )

                        // Optional but recommended: persist a lightweight backfill so it sticks next launch
                        Firestore.firestore()
                            .collection("users").document(currentUid)
                            .collection("contacts").document(userId)
                            .setData([
                                "status": "active",
                                "accepted": true,
                                "source": "backfill",
                                "lastMessageAt": Timestamp(date: messageTimestamp),
                                "unreadCount": isUnread ? 1 : 0,
                                "createdAt": FieldValue.serverTimestamp()
                            ], merge: true)
                    } else {
                        // Already in contacts array → update recency + unread
                        if let idx = self.contacts.firstIndex(where: { $0.id == userId }) {
                            self.contacts[idx].lastMessageAt = messageTimestamp
                            self.contacts[idx].unreadCount = isUnread ? max(1, self.contacts[idx].unreadCount) : 0
                        }

                        // Mirror for stable ordering across sessions
                        Firestore.firestore()
                            .collection("users").document(currentUid)
                            .collection("contacts").document(userId)
                            .setData([
                                "lastMessageAt": Timestamp(date: messageTimestamp),
                                "unreadCount": isUnread ? 1 : 0
                            ], merge: true)
                    }
                }
            }
    }

    // --------------------------------------------------
    // MARK: Pending / Block / Unblock
    // --------------------------------------------------

    func presentAcceptPrompt(otherUid: String) {
        // Auto-accept (you can replace with a confirmation UI if you prefer)
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        let batch = Firestore.firestore().batch()
        let aRef = Firestore.firestore().collection("users").document(currentUid).collection("contacts").document(otherUid)
        let bRef = Firestore.firestore().collection("users").document(otherUid).collection("contacts").document(currentUid)

        batch.setData(["status": "active", "accepted": true, "source": "search", "createdAt": FieldValue.serverTimestamp()], forDocument: aRef, merge: true)
        batch.setData(["status": "active", "accepted": true, "source": "search", "createdAt": FieldValue.serverTimestamp()], forDocument: bRef, merge: true)
        batch.commit { err in
            if let err = err { print("❌ accept error: \(err.localizedDescription)"); return }
            loadContacts()
        }
    }

    func blockContact(_ otherUid: String) {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore()
            .collection("users").document(currentUid)
            .collection("contacts").document(otherUid)
            .setData([
                "status": "blocked",
                "accepted": false
            ], merge: true) { err in
                if let err = err { print("❌ block error: \(err.localizedDescription)"); return }
                loadContacts()
            }
    }

    func unblockContact(_ otherUid: String) {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore()
            .collection("users").document(currentUid)
            .collection("contacts").document(otherUid)
            .setData([
                "status": "active",
                "accepted": true
            ], merge: true) { err in
                if let err = err { print("❌ unblock error: \(err.localizedDescription)"); return }
                loadContacts()
            }
    }

    /// When starting a chat from search/compose → seed pending contact on **both** sides
    func seedPendingIfNeeded(otherUid: String) {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        let myRef = Firestore.firestore().collection("users").document(currentUid).collection("contacts").document(otherUid)
        let theirRef = Firestore.firestore().collection("users").document(otherUid).collection("contacts").document(currentUid)

        let batch = Firestore.firestore().batch()
        batch.setData(["status": "pending", "accepted": false, "source": "search", "createdAt": FieldValue.serverTimestamp()], forDocument: myRef, merge: true)
        batch.setData(["status": "pending", "accepted": false, "source": "search", "createdAt": FieldValue.serverTimestamp()], forDocument: theirRef, merge: true)
        batch.commit { err in
            if let err = err { print("❌ seedPending error: \(err.localizedDescription)"); return }
            loadContacts()
        }
    }

    // --------------------------------------------------
    // MARK: Row
    // --------------------------------------------------

    struct ChatUserRow: View {
        let user: ChatUserProfile
        let preview: String?
        let isUnread: Bool
        let isHighlighted: Bool
        let onTap: () -> Void

        var body: some View {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    if let imageUrl = URL(string: user.profileImageURL ?? "") {
                        AsyncImage(url: imageUrl) { image in
                            image.resizable()
                        } placeholder: {
                            Color.gray
                        }
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())
                    } else {
                        Circle().fill(Color.gray.opacity(0.3))
                            .frame(width: 42, height: 42)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                            .fontWeight((isUnread || isHighlighted) ? .bold : .regular)
                            .foregroundColor(.white)

                        if let preview = preview, !preview.isEmpty {
                            Text(preview)
                                .foregroundColor(.gray)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if isUnread {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

// ======================================================
// MARK: - Group Chat List (single, unified component)
// ======================================================

struct GroupChatListView: View {
    @Binding var showCreateGroup: Bool
    @State private var groups: [GroupChat] = []
    @State private var selectedGroup: GroupChat? = nil
    @State private var unreadGroupIds: Set<String> = []

    var body: some View {
        VStack {
            List(groups) { group in
                NavigationLink(
                    destination: GroupChatRoomView(group: group)
                        .onAppear { unreadGroupIds.remove(group.id) },
                    tag: group,
                    selection: $selectedGroup
                ) {
                    HStack {
                        Text(group.name)
                            .foregroundColor(.white)
                        Spacer()
                        if unreadGroupIds.contains(group.id) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                        }
                    }
                }
            }
            .onAppear {
                fetchGroups()
                listenForUnreadGroupMessages()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)

            Button(action: { showCreateGroup = true }) {
                Label("Create Group", systemImage: "plus")
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .padding()
        }
        .background(Color.black)
    }

    func fetchGroups() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("groups")
            .whereField("members", arrayContains: currentUid)
            .getDocuments { snapshot, error in
                if let error = error {
                    print("❌ Error fetching groups: \(error.localizedDescription)")
                    return
                }
                self.groups = snapshot?.documents.compactMap { GroupChat.from($0) } ?? []
            }
    }

    func listenForUnreadGroupMessages() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        // lightweight “latest message vs lastSeen” check
        for group in groups {
            let groupId = group.id

            Firestore.firestore().collection("groups").document(groupId)
                .collection("messages")
                .order(by: "timestamp", descending: true)
                .limit(to: 1)
                .addSnapshotListener { snapshot, _ in
                    guard let doc = snapshot?.documents.first else { return }
                    let data = doc.data()
                    let senderId = data["senderId"] as? String ?? ""
                    if senderId != currentUid {
                        unreadGroupIds.insert(groupId)
                    }
                }

            Firestore.firestore().collection("groups").document(groupId)
                .collection("readStatus")
                .document(currentUid)
                .addSnapshotListener { snapshot, _ in
                    guard let data = snapshot?.data(),
                          let lastSeen = data["lastSeen"] as? Timestamp else { return }

                    Firestore.firestore().collection("groups").document(groupId)
                        .collection("messages")
                        .order(by: "timestamp", descending: true)
                        .limit(to: 1)
                        .getDocuments { snapshot, _ in
                            guard let latestMessage = snapshot?.documents.first else { return }
                            let latestTime = latestMessage.data()["timestamp"] as? Timestamp ?? Timestamp()
                            if latestTime.dateValue() <= lastSeen.dateValue() {
                                unreadGroupIds.remove(groupId)
                            }
                        }
                }
        }
    }
}

// ======================================================
// MARK: - GroupMessageCard (single definition)
// ======================================================

struct GroupMessageCard: View {
    let message: ChatMessage
    var onLike: () -> Void = {}
    var onComment: () -> Void = {}
    var onRepost: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // text / media
            Group {
                if message.type == "text" {
                    Text(message.text ?? "")
                        .foregroundColor(.white)
                } else if message.type == "image", let urlString = message.mediaURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: { ProgressView() }
                    .frame(maxWidth: 250, maxHeight: 250)
                    .cornerRadius(10)
                } else if message.type == "audio", let url = URL(string: message.mediaURL ?? "") {
                    AudioPlayerView(audioURL: url)
                } else if message.type == "video", let url = URL(string: message.mediaURL ?? "") {
                    VideoPlayerView(videoURL: url).frame(height: 200)
                } else if message.type == "announcement" {
                    Text("📢 " + (message.text ?? ""))
                        .fontWeight(.bold)
                        .foregroundColor(.yellow)
                }
            }

            // Interactions
            HStack(spacing: 20) {
                Button(action: onLike) {
                    Label("\(message.likes.count)", systemImage: "heart")
                        .foregroundColor(.pink)
                }
                Button(action: onComment) {
                    Label("\(message.comments.count)", systemImage: "bubble.right")
                        .foregroundColor(.blue)
                }
                Button(action: onRepost) {
                    Label("\(message.reposts.count)", systemImage: "arrow.2.squarepath")
                        .foregroundColor(.green)
                }
            }
            .font(.caption)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

// ======================================================
// MARK: - Message Bubble + Shapes
// ======================================================

struct MessageBubble: View {
    let message: ChatMessage
    var onEdit: ((ChatMessage) -> Void)? = nil
    var onDelete: ((ChatMessage) -> Void)? = nil
    @State private var showOptions = false

    var body: some View {
        Group {
            if message.type == "text" {
                Text((message.text ?? "") + (message.edited ? " (edited)" : ""))
                    .padding(12)
                    .foregroundColor(message.isSender ? .white : .black)
                    .background(message.isSender ? Color.black : Color.yellow)
                    .clipShape(WaterDropShape(isSender: message.isSender))
            } else if message.type == "image", let urlString = message.mediaURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: { ProgressView() }
                .frame(maxWidth: 250, maxHeight: 250)
                .background(message.isSender ? Color.black : Color.yellow)
                .clipShape(WaterDropShape(isSender: message.isSender))
            } else if message.type == "audio", let urlString = message.mediaURL, let url = URL(string: urlString) {
                AudioPlayerView(audioURL: url)
                    .padding(8)
                    .background(message.isSender ? Color.black : Color.yellow)
                    .clipShape(WaterDropShape(isSender: message.isSender))
            } else if message.type == "video", let urlString = message.mediaURL, let url = URL(string: urlString) {
                VideoPlayerView(videoURL: url)
                    .frame(height: 200)
                    .background(message.isSender ? Color.black : Color.yellow)
                    .clipShape(WaterDropShape(isSender: message.isSender))
            } else {
                Text("Unsupported message type")
                    .padding(12)
                    .foregroundColor(.red)
            }
        }
        .shadow(color: .gray.opacity(0.3), radius: 2, x: 1, y: 1)
        .onLongPressGesture {
            if message.isSender {
                showOptions = true
            }
        }
        .confirmationDialog("Message Options", isPresented: $showOptions) {
            if let onEdit = onEdit {
                Button("Edit") { onEdit(message) }
            }
            if let onDelete = onDelete {
                Button("Delete", role: .destructive) { onDelete(message) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct WaterDropShape: Shape {
    let isSender: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cornerRadius: CGFloat = 18
        let tailSize: CGFloat = 8

        if isSender {
            path.addRoundedRect(
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
            )
            path.move(to: CGPoint(x: rect.maxX - tailSize, y: rect.maxY - 10))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - tailSize, y: rect.maxY - 2), control: CGPoint(x: rect.maxX - 5, y: rect.maxY + 2))
        } else {
            path.addRoundedRect(
                in: CGRect(x: rect.minX + tailSize, y: rect.minY, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
            )
            path.move(to: CGPoint(x: rect.minX + tailSize, y: rect.maxY - 10))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
            path.addQuadCurve(to: CGPoint(x: rect.minX + tailSize, y: rect.maxY - 2), control: CGPoint(x: rect.minX + 5, y: rect.maxY + 2))
        }
        return path
    }
}

// ======================================================
// MARK: - Placeholder Media Views (audio/video)
// ======================================================

struct AudioPlayerView: View {
    let audioURL: URL
    var body: some View {
        VStack { Text("🎧 Audio message").foregroundColor(.blue) }
    }
}

/*struct VideoPlayerView: View {
    let videoURL: URL
    var body: some View {
        VideoPlayer(player: AVPlayer(url: videoURL))
            .cornerRadius(10)
    }
}
*/
// ======================================================
// MARK: - ManageGroupView (unified to `groups` path)
// ======================================================

/*struct ManageGroupView: View {
    var group: GroupChat
    @Environment(\.dismiss) var dismiss
    @State private var users: [ChatUserProfile] = []
    @State private var groupName: String = ""
    @State private var groupDescription: String = ""
    @State private var selectedAdminIds: Set<String> = []
    @State private var selectedOwnerId: String = ""
    @State private var announcementText: String = ""
    @State private var showUserPicker = false
    @State private var coverImage: UIImage? = nil
    @State private var coverImageItem: PhotosPickerItem? = nil
    @State private var coverImageURL: String? = nil
    @State private var confirmDelete = false
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    TextField("Group Name", text: $groupName)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                        .foregroundColor(.white)

                    TextField("Group Description", text: $groupDescription)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                        .foregroundColor(.white)

                    VStack(alignment: .leading) {
                        Text("Admins").foregroundColor(.gray)
                        ForEach(users) { user in
                            Toggle(isOn: Binding<Bool>(
                                get: { selectedAdminIds.contains(user.id) },
                                set: { newValue in
                                    if newValue { selectedAdminIds.insert(user.id) }
                                    else { selectedAdminIds.remove(user.id) }
                                }
                            )) {
                                Text(user.name).foregroundColor(.white)
                            }
                        }
                    }

                    Picker("Primary Owner", selection: $selectedOwnerId) {
                        ForEach(users.filter { selectedAdminIds.contains($0.id) }) { user in
                            Text(user.name).tag(user.id)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .foregroundColor(.white)

                    VStack(alignment: .leading) {
                        Text("Members").foregroundColor(.gray)
                        ForEach(users.filter { group.members.contains($0.id) }) { user in
                            HStack {
                                Text(user.name).foregroundColor(.white)
                                Spacer()
                                if !selectedAdminIds.contains(user.id) {
                                    Button(role: .destructive) { removeUser(user) } label: {
                                        Image(systemName: "minus.circle").foregroundColor(.red)
                                    }
                                }
                            }
                        }

                        Button("Add Members") { showUserPicker = true }
                            .padding(.top)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Group Cover").foregroundColor(.gray)
                        if let image = coverImage {
                            Image(uiImage: image).resizable().scaledToFit().frame(height: 150).cornerRadius(10)
                        }
                        PhotosPicker(selection: $coverImageItem, matching: .images) {
                            Text("Choose Cover Image")
                                .padding()
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                        }
                        .onChange(of: coverImageItem) { newItem in
                            if let newItem {
                                Task {
                                    if let data = try? await newItem.loadTransferable(type: Data.self),
                                       let uiImage = UIImage(data: data) {
                                        self.coverImage = uiImage
                                        uploadCoverImage(uiImage)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send Announcement").foregroundColor(.gray)
                        TextField("Announcement...", text: $announcementText)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                            .foregroundColor(.white)
                        Button("Send") { sendAnnouncement() }
                            .disabled(announcementText.isEmpty)
                    }

                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete Group") }
                        .alert("Are you sure you want to delete this group?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) { deleteGroup() }
                            Button("Cancel", role: .cancel) {}
                        }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle("Manage Group")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { saveChanges() } }
            }
            .onAppear { fetchMembers() }
            .sheet(isPresented: $showUserPicker) {
                UserPickerView { newUser in addUser(newUser) }
            }
        }
    }

    func fetchMembers() {
        Firestore.firestore().collection("users").getDocuments { snapshot, _ in
            let docs = snapshot?.documents ?? []
            self.users = docs.map { doc in
                let id = doc.documentID
                let data = doc.data()
                return ChatUserProfile(
                    id: id,
                    name: data["name"] as? String ?? "",
                    username: data["username"] as? String ?? "",
                    profileImageURL: data["profileImageURL"] as? String
                )
            }

            Firestore.firestore().collection("groups").document(group.id).getDocument { doc, _ in
                let data = doc?.data() ?? [:]
                self.groupName = data["name"] as? String ?? ""
                self.groupDescription = data["description"] as? String ?? ""
                self.coverImageURL = data["coverImageURL"] as? String
                self.selectedAdminIds = Set(data["adminIds"] as? [String] ?? [group.ownerId])
                self.selectedOwnerId = data["ownerId"] as? String ?? group.ownerId
            }
        }
    }

    func addUser(_ user: ChatUserProfile) {
        Firestore.firestore().collection("groups").document(group.id).updateData([
            "members": FieldValue.arrayUnion([user.id])
        ])
        fetchMembers()
    }

    func removeUser(_ user: ChatUserProfile) {
        Firestore.firestore().collection("groups").document(group.id).updateData([
            "members": FieldValue.arrayRemove([user.id]),
            "adminIds": FieldValue.arrayRemove([user.id])
        ]) { error in
            if let error = error {
                print("❌ Failed to remove user: \(error.localizedDescription)")
            } else {
                selectedAdminIds.remove(user.id)
                users.removeAll { $0.id == user.id }
                fetchMembers()
            }
        }
    }

    func saveChanges() {
        var updates: [String: Any] = [
            "name": groupName,
            "description": groupDescription,
            "adminIds": Array(selectedAdminIds),
            "ownerId": selectedOwnerId
        ]
        if let url = coverImageURL { updates["coverImageURL"] = url }

        Firestore.firestore().collection("groups").document(group.id).updateData(updates)
        dismiss()
    }

    func deleteGroup() {
        Firestore.firestore().collection("groups").document(group.id).delete()
        dismiss()
    }

    func sendAnnouncement() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let data: [String: Any] = [
            "text": announcementText,
            "type": "announcement",
            "senderId": uid,
            "timestamp": Timestamp()
        ]
        Firestore.firestore().collection("groups").document(group.id).collection("messages").addDocument(data: data)
        announcementText = ""
    }

    func uploadCoverImage(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else { return }
        let filename = UUID().uuidString + ".jpg"
        let ref = Storage.storage().reference().child("group_covers/\(filename)")

        ref.putData(imageData, metadata: nil) { _, error in
            if let error = error {
                print("❌ Cover upload failed: \(error.localizedDescription)")
                return
            }
            ref.downloadURL { url, _ in
                self.coverImageURL = url?.absoluteString
            }
        }
    }
}
*/
// ======================================================
// MARK: - Helper for Invite Flow (call from your invite completion)
// ======================================================

/// Call this right after an invited user finishes sign-up (when you know both UIDs)
func seedInviteContactsBetween(_ a: String, _ b: String) {
    let batch = Firestore.firestore().batch()
    let aRef = Firestore.firestore().collection("users").document(a).collection("contacts").document(b)
    let bRef = Firestore.firestore().collection("users").document(b).collection("contacts").document(a)

    let payload: [String: Any] = [
        "status": "active",
        "accepted": true,
        "source": "invite",
        "createdAt": FieldValue.serverTimestamp()
    ]
    batch.setData(payload, forDocument: aRef, merge: true)
    batch.setData(payload, forDocument: bRef, merge: true)
    batch.commit { err in
        if let err = err { print("❌ seedInvite error: \(err.localizedDescription)") }
    }
}
