// SharedChatComponents.swift (Complete and working version with all views restored)

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import UniformTypeIdentifiers
import AVKit

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
                CreateGroupChatView()
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

    var body: some View {
        VStack {
            List(users) { user in
                Button {
                    print("📩 Selected user: \(user.name)")
                    selectedRecipient = user
                } label: {
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
                                .foregroundColor(.white)

                            if let preview = lastMessages[user.id] {
                                Text(preview)
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            }
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 6)
                }
            }

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
        let currentUid = Auth.auth().currentUser?.uid ?? ""
        let chatId = [currentUid, userId].sorted().joined(separator: "_")

        Firestore.firestore().collection("directChats").document(chatId).collection("messages")
            .order(by: "timestamp", descending: true)
            .limit(to: 1)
            .getDocuments { snapshot, error in
                guard let doc = snapshot?.documents.first else { return }
                let data = doc.data()
                let preview = data["text"] as? String ?? ""
                lastMessages[userId] = preview
            }
    }
}


// MARK: - GroupChatListView

struct GroupChat: Identifiable {
    var id: String
    var name: String
    var members: [String]
}

struct GroupChatListView: View {
    @Binding var showCreateGroup: Bool
    @State private var groups: [GroupChat] = []

    var body: some View {
        VStack {
            List(groups) { group in
                NavigationLink(destination: GroupChatRoomView(group: group)) {
                    Text(group.name)
                        .foregroundColor(.white)
                }
            }
            .onAppear(perform: fetchGroups)
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

                groups = snapshot?.documents.compactMap { doc in
                    let data = doc.data()
                    let id = doc.documentID
                    let name = data["name"] as? String ?? "Unnamed Group"
                    let members = data["members"] as? [String] ?? []
                    return GroupChat(id: id, name: name, members: members)
                } ?? []
            }
    }
}
// MARK: - Shared Chat Components

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import UniformTypeIdentifiers
import AVKit

// MARK: - Supporting Models







// MARK: - GroupChatRoomView (Social Feed Style)

struct GroupChatRoomView: View {
    var group: GroupChat
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var showMediaPicker = false
    @State private var selectedMedia: URL? = nil
    @State private var commentTarget: ChatMessage? = nil
    @State private var commentText: String = ""

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(messages) { message in
                            GroupMessageCard(
                                message: message,
                                onLike: { toggleLike(message) },
                                onComment: { commentTarget = message },
                                onRepost: { repostMessage(message) }
                            )
                        }
                    }
                    .padding()
                }
            }

            Divider()

            HStack(spacing: 12) {
                TextField("Write something...", text: $messageText)
                    .padding(10)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                    .foregroundColor(.white)

                Button(action: {
                    showMediaPicker = true
                }) {
                    Image(systemName: "paperclip.circle.fill")
                        .foregroundColor(.gray)
                        .font(.title2)
                }
                .fileImporter(
                    isPresented: $showMediaPicker,
                    allowedContentTypes: [.audio, .movie],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let fileURL = urls.first {
                            uploadMedia(fileURL)
                        }
                    case .failure(let error):
                        print("❌ Media selection failed: \(error.localizedDescription)")
                    }
                }

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.blue)
                        .padding(10)
                }
            }
            .padding()
        }
        .navigationTitle(group.name)
        .background(Color.black.ignoresSafeArea())
        .onAppear(perform: loadMessages)
        .sheet(item: $commentTarget) { msg in
            VStack {
                Text("Comment on Post")
                    .font(.headline)
                    .padding(.top)
                TextField("Your comment...", text: $commentText)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                Button("Post") {
                    postComment(to: msg)
                }
                .padding()
                Spacer()
            }
            .padding()
            .background(Color.black)
        }
    }

    func loadMessages() {
        Firestore.firestore().collection("groupChats").document(group.id).collection("messages")
            .order(by: "timestamp")
            .addSnapshotListener { snapshot, error in
                guard let documents = snapshot?.documents else { return }
                messages = documents.map { doc in
                    let data = doc.data()
                    let senderId = data["senderId"] as? String ?? ""
                    return ChatMessage(
                        id: doc.documentID,
                        text: data["text"] as? String,
                        mediaURL: data["mediaURL"] as? String,
                        type: data["type"] as? String ?? "text",
                        isSender: senderId == Auth.auth().currentUser?.uid,
                        documentId: doc.documentID,
                        edited: data["edited"] as? Bool ?? false,
                        likes: data["likes"] as? [String] ?? [],
                        comments: data["comments"] as? [[String: String]] ?? [],
                        reposts: data["reposts"] as? [String] ?? []
                    )
                }
            }
    }

    func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        let data: [String: Any] = [
            "text": messageText,
            "senderId": uid,
            "type": "text",
            "timestamp": Timestamp(),
            "likes": [],
            "comments": [],
            "reposts": []
        ]

        Firestore.firestore().collection("groupChats").document(group.id).collection("messages").addDocument(data: data)
        messageText = ""
    }

    func uploadMedia(_ fileURL: URL) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let ext = fileURL.pathExtension
        let filename = UUID().uuidString + ".\(ext)"
        let ref = Storage.storage().reference().child("group_media/\(filename)")

        ref.putFile(from: fileURL, metadata: nil) { _, error in
            if let error = error {
                print("❌ Upload failed: \(error.localizedDescription)")
                return
            }

            ref.downloadURL { url, _ in
                guard let url = url else { return }
                let type = ext.lowercased().contains("mp4") ? "video" : "audio"
                let data: [String: Any] = [
                    "type": type,
                    "mediaURL": url.absoluteString,
                    "senderId": uid,
                    "timestamp": Timestamp(),
                    "likes": [],
                    "comments": [],
                    "reposts": []
                ]
                Firestore.firestore().collection("groupChats").document(group.id).collection("messages").addDocument(data: data)
            }
        }
    }

    func toggleLike(_ msg: ChatMessage) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard let docId = msg.documentId else { return }
        let ref = Firestore.firestore().collection("groupChats").document(group.id).collection("messages").document(docId)

        let updatedLikes: [String]
        if msg.likes.contains(uid) {
            updatedLikes = msg.likes.filter { $0 != uid }
        } else {
            updatedLikes = msg.likes + [uid]
        }

        ref.updateData(["likes": updatedLikes])
    }

    func postComment(to msg: ChatMessage) {
        guard let uid = Auth.auth().currentUser?.uid, let docId = msg.documentId else { return }
        let ref = Firestore.firestore().collection("groupChats").document(group.id).collection("messages").document(docId)

        let comment = ["userId": uid, "text": commentText]
        ref.updateData(["comments": FieldValue.arrayUnion([comment])])
        commentText = ""
        commentTarget = nil
    }

    func repostMessage(_ msg: ChatMessage) {
        guard let uid = Auth.auth().currentUser?.uid, let docId = msg.documentId else { return }
        let ref = Firestore.firestore().collection("groupChats").document(group.id).collection("messages").document(docId)
        ref.updateData(["reposts": FieldValue.arrayUnion([uid])])
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
            } else if message.type == "audio", let url = URL(string: message.mediaURL ?? "") {
                AudioPlayerView(audioURL: url)
            } else if message.type == "video", let url = URL(string: message.mediaURL ?? "") {
                VideoPlayerView(videoURL: url)
                    .frame(height: 200)
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



// MARK: - DirectChatRoomView

struct DirectChatRoomView: View {
    var recipient: ChatUserProfile
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var showMediaPicker = false
    @State private var selectedMedia: URL? = nil
    @State private var editingMessageId: String? = nil

    var body: some View {
        VStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(
                                message: message,
                                onEdit: { msg in
                                    messageText = msg.text ?? ""
                                    editingMessageId = msg.documentId
                                },
                                onDelete: { msg in
                                    deleteMessage(msg)
                                }
                            )
                            .id(message.id)
                            .frame(maxWidth: .infinity, alignment: message.isSender ? .trailing : .leading)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: messages.count) { _ in
                    withAnimation {
                        scrollProxy.scrollTo(messages.last?.id, anchor: .bottom)
                    }
                }
            }


            HStack(spacing: 12) {
                TextField("Message...", text: $messageText)
                    .padding(10)
                    .background(Color.gray.opacity(0.25))
                    .cornerRadius(20)
                    .foregroundColor(.white)

                Button(action: {
                    showMediaPicker = true
                }) {
                    Image(systemName: "paperclip.circle.fill")
                        .foregroundColor(.gray)
                        .font(.title2)
                }
                .fileImporter(
                    isPresented: $showMediaPicker,
                    allowedContentTypes: [.audio, .movie],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let fileURL = urls.first {
                            uploadMedia(fileURL)
                        }
                    case .failure(let error):
                        print("❌ Media selection failed: \(error.localizedDescription)")
                    }
                }

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.blue)
                        .padding(10)
                }
            }
            .padding()
            .background(Color.black)
        }
        .navigationTitle(recipient.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.gray.opacity(0.15).ignoresSafeArea())
        .onAppear(perform: loadMessages)
    }

    var chatId: String {
        let ids = [recipient.id, Auth.auth().currentUser?.uid ?? ""].sorted()
        return ids.joined(separator: "_")
    }

    func loadMessages() {
        Firestore.firestore().collection("directChats").document(chatId).collection("messages")
            .order(by: "timestamp")
            .addSnapshotListener { snapshot, error in
                guard let documents = snapshot?.documents else { return }

                messages = documents.map { doc in
                    let data = doc.data()
                    let senderId = data["senderId"] as? String ?? "unknown"

                    return ChatMessage(
                        id: doc.documentID,
                        text: data["text"] as? String,
                        mediaURL: data["mediaURL"] as? String,
                        type: data["type"] as? String ?? "text",
                        isSender: senderId == Auth.auth().currentUser?.uid,
                        documentId: doc.documentID,
                        edited: data["edited"] as? Bool ?? false,
                        likes: data["likes"] as? [String] ?? [],
                        comments: data["comments"] as? [[String: String]] ?? [],
                        reposts: data["reposts"] as? [String] ?? []
                    )
                }

            }
    }

    func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        let messageData: [String: Any] = [
            "text": messageText,
            "senderId": uid,
            "type": "text",
            "timestamp": Timestamp(),
            "edited": editingMessageId != nil
        ]

        let messageRef = Firestore.firestore().collection("directChats").document(chatId).collection("messages")

        if let messageId = editingMessageId {
            messageRef.document(messageId).updateData(messageData)
            editingMessageId = nil
        } else {
            messageRef.addDocument(data: messageData)
        }

        messageText = ""
    }

    func uploadMedia(_ fileURL: URL) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let ext = fileURL.pathExtension
        let filename = UUID().uuidString + ".\(ext)"
        let storageRef = Storage.storage().reference().child("chat_media/\(filename)")

        storageRef.putFile(from: fileURL, metadata: nil) { metadata, error in
            if let error = error {
                print("❌ Upload failed: \(error.localizedDescription)")
                return
            }

            storageRef.downloadURL { url, error in
                if let url = url {
                    let type = ext.lowercased().contains("mp4") ? "video" : "audio"
                    sendMediaMessage(url: url.absoluteString, type: type)
                }
            }
        }
    }

    func sendMediaMessage(url: String, type: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let messageData: [String: Any] = [
            "type": type,
            "mediaURL": url,
            "senderId": uid,
            "timestamp": Timestamp()
        ]

        Firestore.firestore().collection("directChats").document(chatId).collection("messages").addDocument(data: messageData)
    }

    func deleteMessage(_ msg: ChatMessage) {
        guard let docId = msg.documentId else { return }

        Firestore.firestore().collection("directChats").document(chatId).collection("messages").document(docId).delete()
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
            } else if message.type == "audio", let urlString = message.mediaURL, let url = URL(string: urlString) {
                AudioPlayerView(audioURL: url)
            } else if message.type == "video", let urlString = message.mediaURL, let url = URL(string: urlString) {
                VideoPlayerView(videoURL: url)
                    .frame(height: 200)
            } else {
                Text("Unsupported message type")
            }
        }
        .padding(12)
        .foregroundColor(message.isSender ? .white : .black)
        .background(message.isSender ? Color.black : Color.white)
        .clipShape(TeardropShape(isSender: message.isSender))
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


// MARK: - UserPickerView

struct UserPickerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var users: [ChatUserProfile] = []
    var onSelect: (ChatUserProfile) -> Void

    var body: some View {
        NavigationStack {
            List(users) { user in
                Button {
                    onSelect(user)
                    dismiss()
                } label: {
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

                        Text(user.name)
                            .foregroundColor(.white)
                    }
                }
            }
            .onAppear(perform: fetchUsers)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Select User")
        }
    }

    func fetchUsers() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }

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
                let username = (data["username"] as? String) ?? id.prefix(6).description
                let profileImageURL = data["profileImageURL"] as? String
                return ChatUserProfile(id: id, name: name, username: username, profileImageURL: profileImageURL)
            } ?? []
        }
    }
}

struct CreateGroupChatView: View {
    @Environment(\.dismiss) var dismiss
    @State private var groupName: String = ""
    @State private var selectedUserIds: Set<String> = []
    @State private var users: [ChatUserProfile] = []

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Group Name", text: $groupName)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)

                List(users) { user in
                    Button(action: {
                        if selectedUserIds.contains(user.id) {
                            selectedUserIds.remove(user.id)
                        } else {
                            selectedUserIds.insert(user.id)
                        }
                    }) {
                        HStack {
                            Text(user.name)
                                .foregroundColor(.white)
                            Spacer()
                            if selectedUserIds.contains(user.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.black)
            }
            .padding()
            .background(Color.black)
            .navigationTitle("Create Group")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        createGroup()
                    }
                    .disabled(groupName.isEmpty || selectedUserIds.isEmpty)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear(perform: fetchUsers)
        }
    }

    func fetchUsers() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }

        Firestore.firestore().collection("users").getDocuments { snapshot, error in
            if let error = error {
                print("❌ Failed to fetch users: \(error.localizedDescription)")
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

            print("✅ Group user list loaded: \(users.count) users")
        }
    }

    func createGroup() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }

        let groupData: [String: Any] = [
            "name": groupName,
            "members": Array(selectedUserIds.union([currentUid])),
            "createdAt": Timestamp()
        ]

        Firestore.firestore().collection("groups").addDocument(data: groupData) { error in
            if let error = error {
                print("❌ Failed to create group: \(error.localizedDescription)")
            } else {
                print("✅ Group created: \(groupName)")
                dismiss()
            }
        }
    }
}
