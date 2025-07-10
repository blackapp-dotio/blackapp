import SwiftUI
import PhotosUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import OneSignalFramework

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
                headerView
                messageScrollView
                messageInputBar
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if group.adminIds.contains(currentUserId) {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showManageSheet = true
                        } label: {
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
            .onAppear {
                if let uid = Auth.auth().currentUser?.uid {
                    currentUserId = uid
                }
                loadMessages()
            }
            .background(Color.black.ignoresSafeArea())
        }
    }

    private var headerView: some View {
        Group {
            if let coverURL = group.coverImageURL, let imageURL = URL(string: coverURL) {
                AsyncImage(url: imageURL) { image in
                    image.resizable()
                         .scaledToFill()
                         .frame(height: 160)
                         .clipped()
                } placeholder: {
                    Color.gray.frame(height: 160)
                }
            } else {
                Color.gray.frame(height: 160)
            }
        }
    }

    private var messageScrollView: some View {
        ScrollViewReader { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let desc = group.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                    }

                    ForEach(messages) { msg in
                        MessageCardView(
                            message: msg,
                            isSender: msg.isSender,
                            toggleLike: { toggleLike(message: msg) },
                            commentAction: { commentTarget = msg },
                            repostAction: { repostMessage(msg) }
                        )
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
    }

    private var messageInputBar: some View {
        HStack {
            TextField("Type a message...", text: $messageText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            Button("Send") {
                sendMessage()
            }
        }
        .padding()
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

    // MARK: - Logic

    private func initials(from name: String) -> String {
        let comps = name.split(separator: " ")
        let first = comps.first?.prefix(1) ?? ""
        let second = comps.dropFirst().first?.prefix(1) ?? ""
        return (first + second).uppercased()
    }

    private func loadMessages() {
        Firestore.firestore().collection("groups").document(group.id).collection("messages")
            .order(by: "timestamp")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                messages = documents.map { doc in
                    let data = doc.data()
                    let senderId = data["senderId"] as? String ?? ""
                    let senderName = data["senderName"] as? String ?? "Someone"
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
                        reposts: data["reposts"] as? [String] ?? [],
                        senderName: senderName
                    )
                }
            }
    }

    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        let db = Firestore.firestore()
        let messageRef = db.collection("groups").document(group.id).collection("messages").document()

        let data: [String: Any] = [
            "id": messageRef.documentID,
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

        messageRef.setData(data)
        messageText = ""
    }

    private func sendMediaMessage(url: String, type: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let db = Firestore.firestore()
        let messageRef = db.collection("groups").document(group.id).collection("messages").document()

        let data: [String: Any] = [
            "id": messageRef.documentID,
            "type": type,
            "mediaURL": url,
            "senderId": uid,
            "senderName": Auth.auth().currentUser?.displayName ?? "Someone",
            "groupId": group.id,
            "timestamp": Timestamp(),
            "likes": [],
            "comments": [],
            "reposts": []
        ]

        messageRef.setData(data)
    }

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
            if likes.contains(userId) {
                likes.removeAll { $0 == userId }
            } else {
                likes.append(userId)
            }
            ref.updateData(["likes": likes])
        }
    }

    private func postComment(messageId: String, commentText: String) {
        guard let currentUserId = Auth.auth().currentUser?.uid else { return }

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
}
