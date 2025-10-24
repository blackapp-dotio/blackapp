import SwiftUI
import PhotosUI
import AVKit
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import OneSignalFramework
import UIKit

// MARK: - Group Story Model

struct GroupStory: Identifiable {
    let id: String
    let userId: String
    let userName: String
    let userAvatarURL: String?
    let mediaURL: String
    let type: String // "image" | "video"
    let timestamp: Timestamp
    let expiresAt: Timestamp
}

// MARK: - View

struct GroupChatRoomView: View {
    var group: GroupChat

    // Chat state
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var commentTarget: ChatMessage? = nil
    @State private var commentText: String = ""
    @State private var currentUserId: String = ""
    @State private var selectedMediaItem: PhotosPickerItem? = nil
    @State private var messageSenderIds: [String: String] = [:]

    // Manage
    @State private var showManageSheet = false

    // Avatars cache
    @State private var userProfiles: [String: (name: String, avatar: String?)] = [:]

    // Stories
    @State private var stories: [GroupStory] = []
    @State private var storyItem: PhotosPickerItem? = nil
    @State private var showStoryViewer: Bool = false
    @State private var activeStoryIndex: Int = 0

    // Listeners
    @State private var chatListener: ListenerRegistration? = nil
    @State private var storyListener: ListenerRegistration? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView
                storiesTray
                messageScrollView
                messageInputBar
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if group.adminIds.contains(currentUserId) {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showManageSheet = true } label: {
                            Image(systemName: "gearshape.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showManageSheet) {
                ManageGroupView(group: group)
            }
            .sheet(item: $commentTarget) { msg in
                commentSheet(for: msg)
            }
            .sheet(isPresented: $showStoryViewer) {
                StoryViewer(stories: stories, startIndex: activeStoryIndex)
                    .background(Color.black.ignoresSafeArea())
            }
            .onAppear {
                if let uid = Auth.auth().currentUser?.uid { currentUserId = uid }
                attachMessageListener()
                attachStoriesListener()
            }
            .onDisappear {
                chatListener?.remove(); chatListener = nil
                storyListener?.remove(); storyListener = nil
            }
            .background(Color.black.ignoresSafeArea())
        }
    }

    // MARK: - Header (cover)

    private var headerView: some View {
        Group {
            if let coverURL = group.coverImageURL, let imageURL = URL(string: coverURL) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        Color.gray.frame(height: 160)
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(height: 160)
                            .clipped()
                    case .failure:
                        Color.gray.frame(height: 160)
                    @unknown default:
                        Color.gray.frame(height: 160)
                    }
                }
            } else {
                Color.gray.frame(height: 160)
            }
        }
    }

    // MARK: - Stories Tray

    private var storiesTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status").font(.headline).foregroundColor(.white)
                Spacer()
                PhotosPicker(selection: $storyItem,
                             matching: .any(of: [.images, .videos]),
                             photoLibrary: .shared()) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Status")
                    }
                    .font(.subheadline)
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .onChange(of: storyItem) { item in
                    guard let item else { return }
                    Task { await handlePickedStory(item) }
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(stories.enumerated()), id: \.element.id) { idx, story in
                        VStack(spacing: 6) {
                            GroupAvatarView(
                                name: story.userName,
                                imageURL: story.userAvatarURL,
                                size: 56,
                                ringColor: .purple
                            )
                            .onTapGesture {
                                activeStoryIndex = idx
                                showStoryViewer = true
                            }
                            Text(story.userName)
                                .lineLimit(1)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 64)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 8)
        .background(Color.black)
    }

    // MARK: - Messages List

    private var messageScrollView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {

                    if let desc = group.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                    }

                    ForEach(messages) { msg in
                        MessageRowView(
                            message: msg,
                            senderProfile: userProfiles[messageSenderIds[msg.id] ?? ""], // ← changed line
                            toggleLike: { toggleLike(message: msg) },
                            commentAction: { commentTarget = msg },
                            repostAction: { repostMessage(msg) },
                            onShare: { shareMessage(msg) }
                        )
                        .id(msg.id)
                        .padding(.horizontal)
                    }

                }
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _ in
                withAnimation {
                    if let last = messages.last {
                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Composer

    private var messageInputBar: some View {
        HStack(spacing: 10) {
            PhotosPicker(
                selection: $selectedMediaItem,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                Image(systemName: "paperclip.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.9))
            }
            .onChange(of: selectedMediaItem) { newItem in
                guard let item = newItem else { return }
                Task { await handlePickedMedia(item) }
            }

            TextField("Type a message…", text: $messageText, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .foregroundColor(.white)

            Button { sendMessage() } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(messageText.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .blue)
                    .padding(.horizontal, 6)
            }
            .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    private func commentSheet(for msg: ChatMessage) -> some View {
        VStack {
            Text("Comment on Post")
                .font(.headline)
                .padding(.top)
            TextField("Your comment...", text: $commentText)
                .padding()
                .background(Color.gray.opacity(0.2))
                .cornerRadius(10)
            Button("Post") {
                postComment(messageId: msg.id, commentText: commentText)
                commentText = ""
                commentTarget = nil
            }
            .padding()
            Spacer()
        }
        .padding()
        .background(Color.black)
    }

    // MARK: - Data & Listeners

    private func attachMessageListener() {
        chatListener?.remove(); chatListener = nil
        chatListener = Firestore.firestore()
            .collection("groups")
            .document(group.id)
            .collection("messages")
            .order(by: "timestamp")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                var next: [ChatMessage] = []
                var missingUserIds = Set<String>()
                var nextSenderIds: [String: String] = [:]

                for doc in documents {
                    let data = doc.data()
                    let senderId = data["senderId"] as? String ?? ""
                    let senderName = data["senderName"] as? String ?? "Someone"

                    let msg = ChatMessage(
                        id: doc.documentID,
                        text: data["text"] as? String,
                        mediaURL: data["mediaURL"] as? String,
                        type: data["type"] as? String ?? "text",
                        isSender: senderId == currentUserId,
                        documentId: doc.documentID,
                        edited: data["edited"] as? Bool ?? false,
                        likes: data["likes"] as? [String] ?? [],
                        comments: data["comments"] as? [[String: String]] ?? [],
                        reposts: data["reposts"] as? [String] ?? [],
                        senderName: senderName
                    )
                    next.append(msg)

                    // Track senderId for this message
                    nextSenderIds[doc.documentID] = senderId

                    // Queue profile fetch if needed
                    if !senderId.isEmpty, userProfiles[senderId] == nil {
                        missingUserIds.insert(senderId)
                    }
                }

                // Commit the senderId map
                messageSenderIds = nextSenderIds

                // Fetch missing profiles (name + avatar)
                if !missingUserIds.isEmpty {
                    let db = Firestore.firestore()
                    for uid in missingUserIds {
                        db.collection("users").document(uid).getDocument { snap, _ in
                            let d = snap?.data() ?? [:]
                            let n = (d["name"] as? String) ?? (d["username"] as? String) ?? "User"
                            let a = d["profileImageURL"] as? String
                            userProfiles[uid] = (n, a)
                        }
                    }
                }

                messages = next
            }
    }


    private func attachStoriesListener() {
        storyListener?.remove(); storyListener = nil
        storyListener = Firestore.firestore()
            .collection("groupStories")
            .document(group.id)
            .collection("items")
            .whereField("expiresAt", isGreaterThan: Timestamp(date: Date()))
            .order(by: "timestamp", descending: true)
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                stories = docs.compactMap { doc in
                    let d = doc.data()
                    guard
                        let userId = d["userId"] as? String,
                        let mediaURL = d["mediaURL"] as? String,
                        let type = d["type"] as? String,
                        let ts = d["timestamp"] as? Timestamp,
                        let exp = d["expiresAt"] as? Timestamp
                    else { return nil }
                    let name = (d["userName"] as? String) ?? "User"
                    let avatar = d["userAvatarURL"] as? String
                    return GroupStory(
                        id: doc.documentID,
                        userId: userId,
                        userName: name,
                        userAvatarURL: avatar,
                        mediaURL: mediaURL,
                        type: type,
                        timestamp: ts,
                        expiresAt: exp
                    )
                }
            }
    }

    // MARK: - Sending

    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        // 🚫 Client-side moderation
        if ProfanityFilter.containsBanned(messageText) {
            // optional: surface a toast if you have a banner system here
            return
        }

        let db = Firestore.firestore()
        let ref = db.collection("groups").document(group.id).collection("messages").document()

        let data: [String: Any] = [
            "id": ref.documentID,
            "text": messageText,
            "senderId": uid,
            "senderName": Auth.auth().currentUser?.displayName ?? "Someone",
            "groupId": group.id,
            "type": "text",
            "timestamp": Timestamp(),
            "likes": [],
            "comments": [],
            "reposts": []
        ]

        ref.setData(data)
        messageText = ""
    }

    private func handlePickedMedia(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let fileExt = item.supportedContentTypes.first?.preferredFilenameExtension,
                  let uid = Auth.auth().currentUser?.uid else {
                selectedMediaItem = nil
                return
            }
            let filename = UUID().uuidString + ".\(fileExt)"
            let storageRef = Storage.storage().reference().child("group_media/\(group.id)/\(filename)")
            _ = try await storageRef.putDataAsync(data)
            let url = try await storageRef.downloadURL()

            let type: String
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                type = "video"
            } else if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                type = "image"
            } else {
                selectedMediaItem = nil
                return
            }

            // Create media message
            let db = Firestore.firestore()
            let ref = db.collection("groups").document(group.id).collection("messages").document()

            let payload: [String: Any] = [
                "id": ref.documentID,
                "type": type,
                "mediaURL": url.absoluteString,
                "senderId": uid,
                "senderName": Auth.auth().currentUser?.displayName ?? "Someone",
                "groupId": group.id,
                "timestamp": Timestamp(),
                "likes": [],
                "comments": [],
                "reposts": []
            ]
            try await ref.setData(payload)
        } catch {
            print("❌ Media upload failed: \(error.localizedDescription)")
        }
        selectedMediaItem = nil
    }

    // MARK: - Stories (upload)

    private func handlePickedStory(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let fileExt = item.supportedContentTypes.first?.preferredFilenameExtension,
                  let uid = Auth.auth().currentUser?.uid else {
                storyItem = nil
                return
            }

            // Fetch my profile for name/avatar to store with story
            let snap = try await Firestore.firestore().collection("users").document(uid).getDocument()
            let myName = (snap.data()?["name"] as? String) ??
                         (Auth.auth().currentUser?.displayName ?? "Me")
            let myAvatar = snap.data()?["profileImageURL"] as? String

            let filename = UUID().uuidString + ".\(fileExt)"
            let ref = Storage.storage().reference().child("group_stories/\(group.id)/\(filename)")
            _ = try await ref.putDataAsync(data)
            let url = try await ref.downloadURL()

            let type: String
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                type = "video"
            } else if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                type = "image"
            } else {
                storyItem = nil
                return
            }

            let now = Date()
            let expires = Calendar.current.date(byAdding: .hour, value: 24, to: now) ?? now.addingTimeInterval(24*3600)

            let docRef = Firestore.firestore()
                .collection("groupStories")
                .document(group.id)
                .collection("items")
                .document()

            try await docRef.setData([
                "userId": uid,
                "userName": myName,
                "userAvatarURL": myAvatar as Any,
                "mediaURL": url.absoluteString,
                "type": type,
                "timestamp": Timestamp(date: now),
                "expiresAt": Timestamp(date: expires)
            ])
        } catch {
            print("❌ Story upload failed: \(error.localizedDescription)")
        }
        storyItem = nil
    }

    // MARK: - Actions

    private func toggleLike(message: ChatMessage) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Firestore.firestore()
            .collection("groups")
            .document(group.id)
            .collection("messages")
            .document(message.id)

        ref.getDocument { document, _ in
            guard let doc = document, doc.exists else { return }
            var likes = doc.data()?["likes"] as? [String] ?? []
            if likes.contains(userId) { likes.removeAll { $0 == userId } }
            else { likes.append(userId) }
            ref.updateData(["likes": likes])
        }
    }

    private func postComment(messageId: String, commentText: String) {
        guard let currentUserId = Auth.auth().currentUser?.uid else { return }

        // 🚫 Client-side moderation
        if ProfanityFilter.containsBanned(commentText) { return }

        let commentData: [String: Any] = [
            "userId": currentUserId,
            "text": commentText,
            "timestamp": Timestamp()
        ]

        Firestore.firestore()
            .collection("groups")
            .document(group.id)
            .collection("messages")
            .document(messageId)
            .collection("comments")
            .addDocument(data: commentData)
    }

    private func repostMessage(_ message: ChatMessage) {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        let ref = Firestore.firestore()
            .collection("groups")
            .document(group.id)
            .collection("messages")
            .document(message.id)

        ref.getDocument { document, _ in
            guard let doc = document, doc.exists else { return }
            var reposts = doc.data()?["reposts"] as? [String] ?? []
            if !reposts.contains(userId) {
                reposts.append(userId)
                ref.updateData(["reposts": reposts])
            }
        }
    }

    private func shareMessage(_ message: ChatMessage) {
        var items: [Any] = []
        if let t = message.text { items.append(t) }
        if let u = message.mediaURL, let url = URL(string: u) { items.append(url) }
        guard !items.isEmpty else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }
}

// MARK: - Message Row (split to help compiler)

private struct MessageRowView: View {
    let message: ChatMessage
    let senderProfile: (name: String, avatar: String?)?
    var toggleLike: () -> Void
    var commentAction: () -> Void
    var repostAction: () -> Void
    var onShare: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GroupAvatarView(
                name: (senderProfile?.name ?? message.senderName),
                imageURL: senderProfile?.avatar,
                size: 34
            )

            GroupMessageCardView(
                message: message,
                isSender: message.isSender,
                toggleLike: toggleLike,
                commentAction: commentAction,
                repostAction: repostAction,
                onShare: onShare
            )
            .frame(maxWidth: .infinity, alignment: message.isSender ? .trailing : .leading)
        }
    }
}

// MARK: - Avatar

private struct GroupAvatarView: View {
    let name: String
    let imageURL: String?
    var size: CGFloat = 36
    var ringColor: Color? = nil

    var body: some View {
        ZStack {
            if let s = imageURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholderInitials
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        placeholderInitials
                    @unknown default:
                        placeholderInitials
                    }
                }
            } else {
                placeholderInitials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(ringColor ?? .clear, lineWidth: ringColor == nil ? 0 : 2)
        )
    }

    private var placeholderInitials: some View {
        Circle()
            .fill(Color.gray.opacity(0.25))
            .overlay(
                Text(initials(from: name))
                    .font(.system(size: max(12, size * 0.38), weight: .semibold))
                    .foregroundColor(.white)
            )
    }

    private func initials(from name: String) -> String {
        let comps = name.split(separator: " ")
        let first = comps.first?.prefix(1) ?? ""
        let second = comps.dropFirst().first?.prefix(1) ?? ""
        return (first + second).uppercased()
    }
}

// MARK: - Message Card (renamed to avoid conflicts)

private struct GroupMessageCardView: View {
    let message: ChatMessage
    let isSender: Bool
    var toggleLike: () -> Void
    var commentAction: () -> Void
    var repostAction: () -> Void
    var onShare: () -> Void

    var body: some View {
        VStack(alignment: isSender ? .trailing : .leading, spacing: 8) {
            if let text = message.text, !text.isEmpty {
                Text(text + (message.edited ? " (edited)" : ""))
                    .padding(12)
                    .foregroundColor(.white)
                    .background(isSender ? Color.black : Color(red: 127/255, green: 0/255, blue: 255/255))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if let mediaURL = message.mediaURL, let url = URL(string: mediaURL) {
                if message.type == "image" {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.25))
                                    .frame(height: 220)
                                ProgressView()
                            }
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        case .failure:
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.25))
                                .frame(height: 220)
                        @unknown default:
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.25))
                                .frame(height: 220)
                        }
                    }
                } else if message.type == "video" {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            HStack(spacing: 18) {
                Button(action: toggleLike) {
                    Label("\(message.likes.count)", systemImage: "hand.thumbsup")
                }
                Button(action: commentAction) {
                    Label("\((message.comments).count)", systemImage: "bubble.right")
                }
                Button(action: repostAction) {
                    Label("\(message.reposts.count)", systemImage: "arrow.2.squarepath")
                }
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .font(.callout)
            .foregroundColor(.white.opacity(0.85))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: isSender ? .trailing : .leading)
    }
}

// MARK: - Story Viewer

private struct StoryViewer: View {
    let stories: [GroupStory]
    @State var index: Int

    init(stories: [GroupStory], startIndex: Int) {
        self.stories = stories
        self._index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if stories.indices.contains(index) {
                let story = stories[index]
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        GroupAvatarView(name: story.userName, imageURL: story.userAvatarURL, size: 28)
                        Text(story.userName).foregroundColor(.white).font(.subheadline).bold()
                        Spacer()
                        Text(relativeTime(story.timestamp.dateValue()))
                            .foregroundColor(.white.opacity(0.7))
                            .font(.caption)
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)

                    if story.type == "image", let url = URL(string: story.mediaURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView().tint(.white)
                            case .success(let img):
                                img.resizable().scaledToFit()
                            case .failure:
                                Color.gray
                            @unknown default:
                                Color.gray
                            }
                        }
                        .frame(maxHeight: 520)
                    } else if story.type == "video", let url = URL(string: story.mediaURL) {
                        VideoPlayer(player: AVPlayer(url: url))
                            .frame(height: 520)
                    }

                    HStack {
                        Button(action: prev) {
                            Image(systemName: "chevron.left").font(.title2)
                        }.disabled(index == 0)

                        Spacer()

                        Button(action: next) {
                            Image(systemName: "chevron.right").font(.title2)
                        }.disabled(index >= stories.count - 1)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                    .foregroundColor(.white)
                }
            } else {
                Text("No story").foregroundColor(.white)
            }
        }
    }

    private func next() { if index < stories.count - 1 { index += 1 } }
    private func prev() { if index > 0 { index -= 1 } }

    private func relativeTime(_ date: Date) -> String {
        let df = RelativeDateTimeFormatter()
        df.unitsStyle = .short
        return df.localizedString(for: date, relativeTo: Date())
    }
}
