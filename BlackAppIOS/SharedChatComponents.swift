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
                CreateGroupView()
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
    var adminIds: [String]
    var ownerId: String
    var description: String?
    var coverImageURL: String?

    static func from(_ doc: DocumentSnapshot) -> GroupChat? {
        let data = doc.data() ?? [:]
        return GroupChat(
            id: doc.documentID,
            name: data["name"] as? String ?? "Unnamed Group",
            members: data["members"] as? [String] ?? [],
            adminIds: data["adminIds"] as? [String] ?? [],
            ownerId: data["ownerId"] as? String ?? "",
            description: data["description"] as? String ?? "",
            coverImageURL: data["coverImageURL"] as? String
        )
    }
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

                groups = snapshot?.documents.compactMap { GroupChat.from($0) } ?? []
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

// MARK: - GroupChatRoomView
/*
import PhotosUI
import SwiftUI
import Firebase
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth

struct GroupChatRoomView: View {
    var group: GroupChat
    
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var commentTarget: ChatMessage? = nil
    @State private var commentText: String = ""
    @State private var showManageSheet = false
    @State private var currentUserId: String = ""
    @State private var selectedMediaItem: PhotosPickerItem? = nil
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let coverURL = group.coverImageURL, let imageURL = URL(string: coverURL) {
                    AsyncImage(url: imageURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(height: 160)
                            .clipped()
                    } placeholder: {
                        Color.gray.frame(height: 160)
                    }
                }
                
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            if let desc = group.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .padding(.bottom, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                            }
                            
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
                    
                    PhotosPicker(
                        selection: $selectedMediaItem,
                        matching: .any(of: [.images, .videos]),
                        photoLibrary: .shared()
                    ) {
                        Image(systemName: "paperclip.circle.fill")
                            .foregroundColor(.gray)
                            .font(.title2)
                    }
                    .onChange(of: selectedMediaItem) { newItem in
                        if let newItem = newItem {
                            Task {
                                if let data = try? await newItem.loadTransferable(type: Data.self),
                                   let fileExtension = newItem.supportedContentTypes.first?.preferredFilenameExtension {
                                    let filename = UUID().uuidString + ".\(fileExtension)"
                                    let ref = Storage.storage().reference().child("group_media/\(filename)")
                                    
                                    ref.putData(data, metadata: nil) { _, error in
                                        if let error = error {
                                            print("❌ Upload failed: \(error.localizedDescription)")
                                            return
                                        }
                                        
                                        ref.downloadURL { url, _ in
                                            guard let url = url else { return }
                                            let type: String
 let fileType = newItem.supportedContentTypes.first!
 if fileType.conforms(to: .movie) {
     type = "video"
 } else if fileType.conforms(to: .image) {
     type = "image"
 } else {
     type = "unsupported"
 }

                                            
                                            if type != "unsupported" {
                                                let data: [String: Any] = [
                                                    "type": type,
                                                    "mediaURL": url.absoluteString,
                                                    "senderId": currentUserId,
                                                    "timestamp": Timestamp(),
                                                    "likes": [],
                                                    "comments": [],
                                                    "reposts": []
                                                ]
                                                Firestore.firestore().collection("groupChats").document(group.id).collection("messages").addDocument(data: data)
                                            } else {
                                                print("❌ Unsupported media type selected.")
                                            }
                                            
                                        }
                                    }
                                }
                            }
                        }
                        
                        Button(action: sendMessage) {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(.blue)
                                .padding(10)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .navigationTitle(group.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if group.adminIds.contains(currentUserId) {
                            Button(action: {
                                showManageSheet = true
                            }) {
                                Image(systemName: "gearshape.fill")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showManageSheet) {
                    ManageGroupView(group: group)
                }
                .background(Color.black.ignoresSafeArea())
                .onAppear {
                    if let uid = Auth.auth().currentUser?.uid {
                        currentUserId = uid
                    }
                    loadMessages()
                }
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
        }
        
        func loadMessages() {
            Firestore.firestore().collection("groupChats").document(group.id).collection("messages")
                .order(by: "timestamp")
                .addSnapshotListener { snapshot, _ in
                    guard let documents = snapshot?.documents else { return }
                    messages = documents.map { doc in
                        let data = doc.data()
                        let senderId = data["senderId"] as? String ?? ""
                        return ChatMessage(
                            id: doc.documentID,
                            text: data["text"] as? String,
                            mediaURL: data["mediaURL"] as? String,
                            type: data["type"] as? String ?? "text",
                            isSender: senderId == currentUserId,
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
    */
    
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

    // MARK: - DirectChatRoomView
 /*
    // import PhotosUI
    
    struct DirectChatRoomView: View {
        var recipient: ChatUserProfile
        @State private var messageText = ""
        @State private var messages: [ChatMessage] = []
        @State private var editingMessageId: String? = nil
        @State private var selectedMediaItem: PhotosPickerItem? = nil
        
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
                    
                    PhotosPicker(
                        selection: $selectedMediaItem,
                        matching: .any(of: [.images, .videos]),
                        photoLibrary: .shared()
                    ) {
                        Image(systemName: "paperclip.circle.fill")
                            .foregroundColor(.gray)
                            .font(.title2)
                    }
                    .onChange(of: selectedMediaItem) { newItem in
                        if let newItem = newItem {
                            Task {
                                if let data = try? await newItem.loadTransferable(type: Data.self),
                                   let fileExtension = newItem.supportedContentTypes.first?.preferredFilenameExtension {
                                    let filename = UUID().uuidString + ".\(fileExtension)"
                                    let storageRef = Storage.storage().reference().child("chat_media/\(filename)")
                                    
                                    storageRef.putData(data, metadata: nil) { _, error in
                                        if let error = error {
                                            print("❌ Upload failed: \(error.localizedDescription)")
                                            return
                                        }
                                        
                                        storageRef.downloadURL { url, _ in
                                            if let url = url {
                                                let type: String
  let fileType = newItem.supportedContentTypes.first!
  if fileType.conforms(to: .movie) {
      type = "video"
  } else if fileType.conforms(to: .image) {
      type = "image"
  } else {
      type = "unsupported"
  }

                                                sendMediaMessage(url: url.absoluteString, type: type)
                                            }
                                        }
                                    }
                                }
                            }
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
                .addSnapshotListener { snapshot, _ in
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
    */
    
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
            } else if message.type == "image", let urlString = message.mediaURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(maxWidth: 250, maxHeight: 250) // Adjust as needed
                .cornerRadius(10)
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
/*
    struct UserPickerView: View {
        @Environment(\.dismiss) var dismiss
        @State private var users: [ChatUserProfile] = []
        @State private var searchText: String = ""
        var onSelect: (ChatUserProfile) -> Void
        
        var body: some View {
            NavigationStack {
                VStack {
                    TextField("Search users...", text: $searchText)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                    
                    List(filteredUsers) { user in
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
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                }
                .background(Color.black)
                .navigationTitle("Select User")
                .onAppear(perform: fetchUsers)
            }
        }
        
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
                    let username = data["username"] as? String ?? ""
                    let profileImageURL = data["profileImageURL"] as? String
                    return ChatUserProfile(id: id, name: name, username: username, profileImageURL: profileImageURL)
                } ?? []
            }
        }
    }
    
    
    struct CreateGroupChatView: View {
        @Environment(\.dismiss) var dismiss
        @State private var groupName: String = ""
        @State private var groupDescription: String = ""
        @State private var coverImage: UIImage? = nil
        @State private var showImagePicker = false
        @State private var users: [ChatUserProfile] = []
        @State private var selectedUserIds: Set<String> = []
        
        var body: some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Group name", text: $groupName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    TextField("Description (optional)", text: $groupDescription)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Button(action: {
                        showImagePicker = true
                    }) {
                        if let image = coverImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 120)
                                .cornerRadius(10)
                        } else {
                            HStack {
                                Image(systemName: "photo")
                                Text("Add cover image")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(10)
                        }
                    }
                    .sheet(isPresented: $showImagePicker) {
                        ImagePicker(selectedImage: $coverImage) // ✅ Corrected
                    }
                    
                    Text("Add members:")
                        .font(.headline)
                    
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
                                Spacer()
                                if selectedUserIds.contains(user.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Button("Create Group") {
                        createGroup()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding()
                .navigationTitle("New Group")
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
                "description": groupDescription,
                "members": Array(selectedUserIds.union([currentUid])),
                "adminIds": [currentUid],
                "creatorId": currentUid,
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
    */
    
    
    /*import SwiftUI
     import Firebase
     import FirebaseFirestore
     import FirebaseStorage */

    import PhotosUI
    
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
 /*   /*import SwiftUI
     import Firebase
     import FirebaseFirestore
     import FirebaseAuth
     import FirebaseStorage
     import PhotosUI*/
    
    struct CreateGroupView: View {
        @Environment(\.dismiss) var dismiss
        
        @State private var groupName: String = ""
        @State private var groupDescription: String = ""
        @State private var coverImage: UIImage? = nil
        @State private var coverImageItem: PhotosPickerItem? = nil
        @State private var coverImageURL: String? = nil
        @State private var isCreating = false
        
        
        var body: some View {
            NavigationStack {
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
                        Text("Group Cover Image")
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
                    
                    Button(action: createGroup) {
                        Text("Create Group")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isCreating ? Color.gray : Color.blue)
                            .cornerRadius(10)
                            .foregroundColor(.white)
                    }
                    .disabled(isCreating || groupName.isEmpty)
                }
                .padding()
                .background(Color.black.ignoresSafeArea())
                .navigationTitle("New Group")
            }
        }
        
        func createGroup() {
            guard let currentUserId = Auth.auth().currentUser?.uid else {
                print("❌ No authenticated user.")
                return
            }
            
            isCreating = true
            let groupId = UUID().uuidString
            
            let groupData: [String: Any] = [
                "name": groupName,
                "description": groupDescription,
                "members": [currentUserId],
                "adminIds": [Auth.auth().currentUser?.uid ?? ""],
                "ownerId": currentUserId,
                "coverImageURL": coverImageURL ?? ""
            ]
            
            Firestore.firestore().collection("groups").document(groupId).setData(groupData) { error in
                isCreating = false
                if let error = error {
                    print("❌ Failed to create group: \(error.localizedDescription)")
                } else {
                    print("✅ Group created with ID: \(groupId)")
                    dismiss()
                }
            }
        }
        
        func uploadCoverImage(_ image: UIImage) {
            guard let imageData = image.jpegData(compressionQuality: 0.8) else { return }
            let filename = UUID().uuidString + ".jpg"
            let ref = Storage.storage().reference().child("group_covers/\(filename)")
            
            ref.putData(imageData, metadata: nil) { _, error in
                if let error = error {
                    print("❌ Upload failed: \(error.localizedDescription)")
                    return
                }
                
                ref.downloadURL { url, _ in
                    self.coverImageURL = url?.absoluteString
                    print("✅ Cover image uploaded: \(self.coverImageURL ?? "none")")
                }
            }
        }
    }
}
*/
