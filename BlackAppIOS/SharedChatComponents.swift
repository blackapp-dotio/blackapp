// SharedChatComponents.swift (Complete and working version with all views restored)


// MARK: - GroupChatListView

import Foundation
import FirebaseFirestore

struct GroupChat: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var description: String?
    var coverImageURL: String?
    var ownerId: String
    var members: [String]
    var adminIds: [String] // ✅ Add this line

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
            adminIds: data["adminIds"] as? [String] ?? [] // ✅ Graceful fallback
        )
    }
}


import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import UniformTypeIdentifiers
import AVKit
import PhotosUI
// MARK: - ChatTabView

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
                _ = TokenSyncMonitor.shared  // Re-activates or confirms token monitor
            }
            .preferredColorScheme(.dark)
            .background(Color.black.ignoresSafeArea())
        }
    }
}

// MARK: - DirectChatListView

struct DirectChatListView: View {
    @State private var users: [ChatUserProfile] = []
    @State private var selectedRecipient: ChatUserProfile? = nil
    @State private var lastMessages: [String: String] = [:]
    @State private var showUserPicker = false
    @State private var searchText: String = ""
    @State private var unreadChats: Set<String> = []
    @State private var selectedGroup: GroupChat? = nil

    @ObservedObject var router = NotificationRouter.shared
    
    var body: some View {
        VStack {
            // 🔍 Search Bar
            TextField("Search users...", text: $searchText)
                .padding(10)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
                .foregroundColor(.white)
                .padding(.horizontal)
            
            // 📋 Filtered user list
            List(filteredUsers) { user in
                ChatUserRow(
                    user: user,
                    preview: lastMessages[user.id],
                    isUnread: unreadChats.contains(user.id),
                    isHighlighted: user.id == router.selectedChatUser?.id,
                    onTap: {
                        selectedRecipient = user
                        router.selectedChatUser = nil
                    }
                )
            }
            .id(router.selectedChatUser?.id ?? UUID().uuidString) // ✅ Force refresh
            
            
            NavigationLink(destination: selectedRecipient.map { DirectChatRoomView(recipient: $0) }, isActive: Binding<Bool>(
                get: { selectedRecipient != nil },
                set: { if !$0 { selectedRecipient = nil } }
            )) {
                EmptyView()
            }
            .hidden()
        }
        .onAppear(perform: fetchUsers)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showUserPicker = true
                }) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(.white)
                }
            }
        }
        .sheet(isPresented: $showUserPicker) {
            UserPickerView { selectedUser in
                print("👤 Picked user: \(selectedUser.name)")
                self.selectedRecipient = selectedUser
            }
        }
    }
    
    // 🔁 Filter users by name (case insensitive)
    var filteredUsers: [ChatUserProfile] {
        if searchText.isEmpty {
            return users
        } else {
            return users.filter {
                $0.name.lowercased().contains(searchText.lowercased())
            }
        }
    }
    
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
            
            users.forEach { user in
                fetchLastMessage(with: user.id)
            }
        }
    }
    
    func fetchLastMessage(with userId: String) {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }
        let chatId = [currentUid, userId].sorted().joined(separator: "_")
        
        let messagesRef = Firestore.firestore().collection("directChats").document(chatId)
        
        // 1. Fetch last message timestamp
        messagesRef.collection("messages")
            .order(by: "timestamp", descending: true)
            .limit(to: 1)
            .getDocuments { snapshot, error in
                guard let doc = snapshot?.documents.first else { return }
                let data = doc.data()
                let preview = data["text"] as? String ?? ""
                let messageTimestamp = (data["timestamp"] as? Timestamp)?.dateValue() ?? Date.distantPast
                lastMessages[userId] = preview
                
                // 2. Compare to user's lastSeen
                messagesRef.collection("readStatus").document(currentUid).getDocument { readSnap, _ in
                    let lastSeen = (readSnap?.data()?["lastSeen"] as? Timestamp)?.dateValue() ?? Date.distantPast
                    
                    if messageTimestamp > lastSeen {
                        unreadChats.insert(userId)
                    } else {
                        unreadChats.remove(userId)
                    }
                }
            }
    }
    
    
    // MARK: - Subview: ChatUserRow
    
    struct ChatUserRow: View {
        let user: ChatUserProfile
        let preview: String?
        let isUnread: Bool
        let isHighlighted: Bool
        let onTap: () -> Void
        
        var body: some View {
            Button(action: onTap) {
                HStack {
                    if let imageUrl = URL(string: user.profileImageURL ?? "") {
                        AsyncImage(url: imageUrl) { image in
                            image.resizable()
                        } placeholder: {
                            Color.gray
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    }
                    
                    VStack(alignment: .leading) {
                        Text(user.name)
                            .fontWeight((isUnread || isHighlighted) ? .bold : .regular)
                            .foregroundColor(.white)
                        
                        if let preview = preview {
                            Text(preview)
                                .foregroundColor(.gray)
                                .font(.caption)
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
    
    
    // MARK: - GroupChatListView


    struct GroupChatListView: View {
        @Binding var showCreateGroup: Bool
        @State private var groups: [GroupChat] = []
        @State private var selectedGroup: GroupChat?
        @ObservedObject var notificationRouter = NotificationRouter.shared

        var body: some View {
            VStack {
                NavigationStack {
                    List(groups) { group in
                        ZStack {
                            // Invisible NavigationLink for programmatic navigation
                            NavigationLink(
                                destination: GroupChatRoomView(group: group)
                                    .onAppear {
                                        notificationRouter.unreadChatIds.removeAll(where: { $0 == group.id })
                                    },
                                tag: group,
                                selection: $selectedGroup
                            ) {
                                EmptyView()
                            }
                            .opacity(0)

                            HStack {
                                Text(group.name)
                                    .foregroundColor(.white)

                                if notificationRouter.unreadChatIds.contains(group.id) {
                                    Spacer()
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 10, height: 10)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedGroup = group
                            }
                        }
                    }
                    .onAppear {
                        fetchGroups()
                        handleIncomingDeepLink()
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                }

                Button(action: {
                    showCreateGroup = true
                }) {
                    Label("Create Group", systemImage: "plus")
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding()
            }
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

        func handleIncomingDeepLink() {
            if let matchedGroup = groups.first(where: { notificationRouter.selectedGroupId == $0.id }) {
                selectedGroup = matchedGroup
                notificationRouter.selectedGroupId = nil
            }
        }
    }

    // MARK: - GroupMessageCard
    
    struct GroupMessageCard: View {
        let message: ChatMessage
        var onLike: () -> Void
        var onComment: () -> Void
        var onRepost: () -> Void
        
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if message.type == "text" {
                    Text(message.text ?? "")
                        .foregroundColor(.white)
                } else if message.type == "image", let urlString = message.mediaURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxWidth: 250, maxHeight: 250)
                    .cornerRadius(10)
                } else if message.type == "audio", let url = URL(string: message.mediaURL ?? "") {
                    AudioPlayerView(audioURL: url)
                } else if message.type == "video", let url = URL(string: message.mediaURL ?? "") {
                    VideoPlayerView(videoURL: url)
                        .frame(height: 200)
                }
                
                if message.type == "announcement" {
                    Text("📢 " + (message.text ?? ""))
                        .fontWeight(.bold)
                        .foregroundColor(.yellow)
                }
                
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
    

    
    // MARK: - MessageBubble & TeardropShape

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
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
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

    
    // MARK: - Placeholder Media Views
    
    struct AudioPlayerView: View {
        let audioURL: URL
        
        var body: some View {
            VStack {
                Text("🎧 Audio message")
                    .foregroundColor(.blue)
            }
        }
    }
    
    struct VideoPlayerView: View {
        let videoURL: URL
        
        var body: some View {
            VideoPlayer(player: AVPlayer(url: videoURL))
                .cornerRadius(10)
        }
    }
    
    
    struct TeardropShape: Shape {
        let isSender: Bool
        
        func path(in rect: CGRect) -> Path {
            var path = Path()
            
            let cornerRadius: CGFloat = 18
            let tailSize: CGFloat = 8
            
            if isSender {
                path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailSize, height: rect.height), cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
                path.move(to: CGPoint(x: rect.maxX - tailSize, y: rect.maxY - 10))
                path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
                path.addQuadCurve(to: CGPoint(x: rect.maxX - tailSize, y: rect.maxY - 2), control: CGPoint(x: rect.maxX - 5, y: rect.maxY + 2))
            } else {
                path.addRoundedRect(in: CGRect(x: rect.minX + tailSize, y: rect.minY, width: rect.width - tailSize, height: rect.height), cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
                path.move(to: CGPoint(x: rect.minX + tailSize, y: rect.maxY - 10))
                path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
                path.addQuadCurve(to: CGPoint(x: rect.minX + tailSize, y: rect.maxY - 2), control: CGPoint(x: rect.minX + 5, y: rect.maxY + 2))
            }
            
            return path
        }
    }
    
    
 
    struct ManageGroupView: View {
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
                            Text("Admins")
                                .foregroundColor(.gray)
                            ForEach(users) { user in
                                Toggle(isOn: Binding<Bool>(
                                    get: { selectedAdminIds.contains(user.id) },
                                    set: { newValue in
                                        if newValue {
                                            selectedAdminIds.insert(user.id)
                                        } else {
                                            selectedAdminIds.remove(user.id)
                                        }
                                    }
                                )) {
                                    Text(user.name)
                                        .foregroundColor(.white)
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
                            Text("Members")
                                .foregroundColor(.gray)
                            ForEach(users.filter { group.members.contains($0.id) }) { user in
                                HStack {
                                    Text(user.name)
                                        .foregroundColor(.white)
                                    Spacer()
                                    if !selectedAdminIds.contains(user.id) {
                                        Button(role: .destructive) {
                                            removeUser(user)
                                        } label: {
                                            Image(systemName: "minus.circle")
                                                .foregroundColor(.red)
                                        }
                                    }
                                }
                            }
                            
                            Button("Add Members") {
                                showUserPicker = true
                            }
                            .padding(.top)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Group Cover")
                                .foregroundColor(.gray)
                            
                            if let image = coverImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 150)
                                    .cornerRadius(10)
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
                            Text("Send Announcement")
                                .foregroundColor(.gray)
                            TextField("Announcement...", text: $announcementText)
                                .padding()
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                                .foregroundColor(.white)
                            
                            Button("Send") {
                                sendAnnouncement()
                            }
                            .disabled(announcementText.isEmpty)
                        }
                        
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Text("Delete Group")
                        }
                        .alert("Are you sure you want to delete this group?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) {
                                deleteGroup()
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                    .padding()
                }
                .background(Color.black)
                .navigationTitle("Manage Group")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            saveChanges()
                        }
                    }
                }
                .onAppear {
                    fetchMembers()
                }
                .sheet(isPresented: $showUserPicker) {
                    UserPickerView { newUser in
                        addUser(newUser)
                    }
                }
            }
        }
        
        func fetchMembers() {
            Firestore.firestore().collection("users").getDocuments { snapshot, error in
                guard let documents = snapshot?.documents else { return }
                self.users = documents.compactMap { doc in
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
                    // 🔥 Update local state after removal
                    selectedAdminIds.remove(user.id)
                    users.removeAll { $0.id == user.id }
                    fetchMembers() // refresh everything
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
            if let url = coverImageURL {
                updates["coverImageURL"] = url
            }
            
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
            Firestore.firestore().collection("groupChats").document(group.id).collection("messages").addDocument(data: data)
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
}

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore



struct GroupChatListView: View {
    @Binding var showCreateGroup: Bool
    @State private var groups: [GroupChat] = []
    @State private var selectedGroup: GroupChat? = nil
    @State private var unreadGroupIds: Set<String> = []

    var body: some View {
        VStack {
            List(groups, id: \.self) { group in
                NavigationLink(
                    destination: GroupChatRoomView(group: group),
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
            .onAppear(perform: {
                fetchGroups()
                listenForUnreadGroupMessages()
            })
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)

            Button(action: {
                showCreateGroup = true
            }) {
                Label("Create Group", systemImage: "plus")
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .padding()
        }
    }

    func fetchGroups() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }

        Firestore.firestore().collection("groups").whereField("members", arrayContains: currentUid)
            .getDocuments { snapshot, error in
                if let error = error {
                    print("❌ Error fetching groups: \(error.localizedDescription)")
                    return
                }

                groups = snapshot?.documents.compactMap { GroupChat.from($0) } ?? []
            }
    }

    func listenForUnreadGroupMessages() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }

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
// MARK: - GroupMessageCard.swift
struct GroupMessageCard: View {
    let message: ChatMessage
    var onLike: () -> Void = {}
    var onComment: () -> Void = {}
    var onRepost: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading) {
            Text(message.text ?? "")
                .foregroundColor(.white)
            // Add audio/video display logic as needed
        }
        .padding()
        .background(Color.gray.opacity(0.2))
        .cornerRadius(10)
    }
}


// MARK: - ManageGroupView.swift
struct ManageGroupView: View {
    let group: GroupChat

    var body: some View {
        VStack {
            Text("Manage \(group.name)")
                .font(.title)
                .foregroundColor(.white)
            // Add group management tools here
        }
        .padding()
        .background(Color.black)
    }
}
