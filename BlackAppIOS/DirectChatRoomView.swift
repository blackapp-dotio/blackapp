import PhotosUI
import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import OneSignalFramework
import FirebaseFunctions

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
                        if let last = messages.last {
                            scrollProxy.scrollTo(last.id, anchor: .bottom)
                        }
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
                            do {
                                if let data = try await newItem.loadTransferable(type: Data.self),
                                   let fileExtension = newItem.supportedContentTypes.first?.preferredFilenameExtension {
                                    let filename = UUID().uuidString + ".\(fileExtension)"
                                    let ref = Storage.storage().reference().child("chat_media/\(filename)")
                                    try await ref.putDataAsync(data)

                                    let url = try await ref.downloadURL()
                                    let type: String
                                    if newItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                                        type = "video"
                                    } else if newItem.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                                        type = "image"
                                    } else {
                                        print("❌ Unsupported media type.")
                                        return
                                    }
                                    sendMediaMessage(url: url.absoluteString, type: type)
                                }
                            } catch {
                                print("❌ Media upload failed: \(error.localizedDescription)")
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

    func deleteMessage(_ msg: ChatMessage) {
        guard let docId = msg.documentId else { return }
        Firestore.firestore()
            .collection("directChats")
            .document(chatId)
            .collection("messages")
            .document(docId)
            .delete()
    }

    func loadMessages() {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        Firestore.firestore()
            .collection("directChats")
            .document(chatId)
            .collection("messages")
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
                        isSender: senderId == uid,
                        documentId: doc.documentID,
                        edited: data["edited"] as? Bool ?? false,
                        likes: data["likes"] as? [String] ?? [],
                        comments: data["comments"] as? [[String: String]] ?? [],
                        reposts: data["reposts"] as? [String] ?? [], senderName: senderId == uid ? "" : self.recipient.name
                    )
                }

                // ✅ Mark chat as read
                Firestore.firestore()
                    .collection("directChats")
                    .document(chatId)
                    .collection("readStatus")
                    .document(uid)
                    .setData(["lastSeen": FieldValue.serverTimestamp()], merge: true)
            }
    }

    func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        let messageData: [String: Any] = [
            "text": messageText,
            "senderId": uid,
            "recipientId": recipient.id,
            "type": "text",
            "timestamp": Timestamp(),
            "edited": editingMessageId != nil
        ]

        let chatRef = Firestore.firestore().collection("directChats").document(chatId)

        // ✅ Save lastMessageTimestamp for chat list
        chatRef.setData([
            "lastMessageTimestamp": FieldValue.serverTimestamp(),
            "lastMessageSender": uid
        ], merge: true)

        // ✅ Save or update message
        if let messageId = editingMessageId {
            chatRef.collection("messages").document(messageId).updateData(messageData)
            editingMessageId = nil
        } else {
            chatRef.collection("messages").addDocument(data: messageData)
        }

        // ✅ Update read status
        chatRef.collection("readStatus").document(uid).setData([
            "lastSeen": FieldValue.serverTimestamp()
        ], merge: true)

        // ✅ Notify recipient
        sendDirectChatNotification(to: recipient)

        messageText = ""
    }

    func sendMediaMessage(url: String, type: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let messageData: [String: Any] = [
            "type": type,
            "mediaURL": url,
            "senderId": uid,
            "recipientId": recipient.id,
            "timestamp": Timestamp()
        ]

        let chatRef = Firestore.firestore().collection("directChats").document(chatId)
        chatRef.collection("messages").addDocument(data: messageData)

        chatRef.collection("readStatus").document(uid).setData([
            "lastSeen": FieldValue.serverTimestamp()
        ], merge: true)

        sendDirectChatNotification(to: recipient)
    }

    func sendDirectChatNotification(to recipient: ChatUserProfile) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let payload: [String: Any] = [
            "recipientId": recipient.id,
            "message": messageText.trimmingCharacters(in: .whitespaces),
            "senderId": uid,
            "senderName": Auth.auth().currentUser?.displayName ?? "Someone",
            "chatId": chatId
        ]

        Functions.functions().httpsCallable("sendNewMessageNotification").call(payload) { result, error in
            if let error = error {
                print("❌ Failed to send notification: \(error.localizedDescription)")
            } else if let response = result?.data {
                print("✅ Notification sent: \(response)")
            } else {
                print("⚠️ No response from notification function.")
            }
        }
    }
}
struct MessageBubble: View {
    let message: ChatMessage
    var onEdit: (ChatMessage) -> Void
    var onDelete: (ChatMessage) -> Void
    
    var body: some View {
        VStack(alignment: message.isSender ? .trailing : .leading, spacing: 4) {
            if let text = message.text {
                Text(text)
                    .padding()
                    .foregroundColor(message.isSender ? .white : .white)
                    .background(
                        ZStack {
                            (message.isSender ? Color.brown : Color.purple)
                                                    .opacity(0.8)
                                                Color.clear
                                                    .background(.ultraThinMaterial)
                        }
                    )
                    .clipShape(WaterDropShape(isSender: message.isSender))
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 1, y: 1)
            }
    

            if let mediaURL = message.mediaURL, let url = URL(string: mediaURL) {
                if message.type == "image" {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxHeight: 200)
                    .cornerRadius(12)
                } else if message.type == "video" {
                    VideoPlayerView(videoURL: url)
                        .frame(height: 200)
                        .cornerRadius(12)
                }
            }

            HStack {
                if message.isSender {
                    Button(action: { onEdit(message) }) {
                        Image(systemName: "pencil").font(.caption)
                    }
                    Button(action: { onDelete(message) }) {
                        Image(systemName: "trash").font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isSender ? .trailing : .leading)
    }
}

import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL

    var body: some View {
        VideoPlayer(player: AVPlayer(url: videoURL))
            .cornerRadius(10)
            .onDisappear {
                // Stop video when navigating away
                AVPlayer(url: videoURL).pause()
            }
    }
}
