import PhotosUI
import SwiftUI
import AVKit
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import OneSignalFramework
import FirebaseFunctions

// MARK: - DirectChatRoomView with DM gate (requests + block + decline)

struct DirectChatRoomView: View {
    var recipient: ChatUserProfile

    // UI state
    @Environment(\.dismiss) private var dismiss
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var editingMessageId: String? = nil
    @State private var selectedMediaItem: PhotosPickerItem? = nil
    @State private var showBlockConfirm = false
    @State private var showUnblockConfirm = false
    @State private var infoToast: String? = nil

    // Gate (security) state
    @State private var gate: DMGateState = .accepted
    @State private var loadingGate = true
    @State private var meProfile: ChatUserProfile? = nil

    // Firestore listener
    @State private var messagesListener: ListenerRegistration? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Top gate banner
            GateBannerView(
                loading: loadingGate,
                gate: gate,
                recipientName: recipient.name,
                onAccept: { acceptRequest() },
                onDecline: { declineRequest() },
                onBlock: { showBlockConfirm = true }
            )

            // Message list
            MessageListView(
                messages: messages,
                recipientName: recipient.name,
                onEdit: { msg in
                    guard gate == .accepted else { return }
                    messageText = msg.text ?? ""
                    editingMessageId = msg.documentId
                },
                onDelete: { msg in
                    guard gate == .accepted else { return }
                    deleteMessage(msg)
                }
            )

            // Composer
            ComposerView(
                gate: gate,
                messageText: $messageText,
                selectedMediaItem: $selectedMediaItem,
                onSend: { text in sendTapped(text: text) },
                onPickMedia: { item in Task { await handlePickedMedia(item) } }
            )
            .padding(.vertical, 8)
            .padding(.horizontal)
            .background(Color.black)
        }
        .navigationTitle(recipient.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.gray.opacity(0.15).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    switch gate {
                    case .blockedByMe:
                        Button("Unblock \(recipient.name)") { showUnblockConfirm = true }
                    default:
                        Button("Block \(recipient.name)", role: .destructive) { showBlockConfirm = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.white)
                }
            }
        }
        .onAppear {
            loadMeProfile()
            refreshGate(andAttachListener: true)
        }
        .onDisappear { detachMessagesListener() }
        .alert("Block \(recipient.name)?", isPresented: $showBlockConfirm) {
            Button("Block", role: .destructive) { blockUser() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Unblock \(recipient.name)?", isPresented: $showUnblockConfirm) {
            Button("Unblock") { unblockUser() }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .top) {
            if let toast = infoToast {
                Text(toast)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .clipShape(Capsule())
                    .padding(.top, 6)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { infoToast = nil }
                    }
            }
        }
    }

    // MARK: - Computed

    var chatId: String {
        let uid = Auth.auth().currentUser?.uid ?? ""
        return DMRelationshipService.chatId(with: recipient.id, me: uid)
    }

    // MARK: - Gate + profile

    private func refreshGate(andAttachListener: Bool) {
        loadingGate = true
        DMRelationshipService.shared.gateState(with: recipient.id) { state in
            gate = state
            loadingGate = false

            if state == .accepted {
                if andAttachListener { attachMessagesListener() }
            } else {
                detachMessagesListener()
                messages = [] // keep thread hidden until accepted
            }
        }
    }

    private func loadMeProfile() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid).getDocument { doc, _ in
            let data = doc?.data() ?? [:]
            meProfile = ChatUserProfile(
                id: uid,
                name: data["name"] as? String ?? (Auth.auth().currentUser?.displayName ?? "Me"),
                username: data["username"] as? String ?? "",
                profileImageURL: data["profileImageURL"] as? String
            )
        }
    }

    // MARK: - Listener

    private func attachMessagesListener() {
        detachMessagesListener()
        guard let uid = Auth.auth().currentUser?.uid else { return }

        messagesListener = Firestore.firestore()
            .collection("directChats")
            .document(chatId)
            .collection("messages")
            .order(by: "timestamp")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                messages = docs.map { doc in
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
                        reposts: data["reposts"] as? [String] ?? [],
                        senderName: senderId == uid ? "" : recipient.name
                    )
                }

                // mark read
                Firestore.firestore()
                    .collection("directChats")
                    .document(chatId)
                    .collection("readStatus")
                    .document(uid)
                    .setData(["lastSeen": FieldValue.serverTimestamp()], merge: true)
            }
    }

    private func detachMessagesListener() {
        messagesListener?.remove()
        messagesListener = nil
    }

    // MARK: - Actions (gate)

    private func acceptRequest() {
        DMRelationshipService.shared.acceptRequest(from: recipient.id) { err in
            if let err = err {
                print("❌ acceptRequest error: \(err.localizedDescription)")
                infoToast = "Couldn’t accept request."
                return
            }
            infoToast = "Request accepted."
            refreshGate(andAttachListener: true)
        }
    }

    private func declineRequest() {
        DMRelationshipService.shared.declineRequest(from: recipient.id) { err in
            if let err = err {
                print("❌ declineRequest error: \(err.localizedDescription)")
                infoToast = "Couldn’t decline."
                return
            }
            infoToast = "Request declined."
            refreshGate(andAttachListener: false) // back to needsRequest
        }
    }

    private func blockUser() {
        DMRelationshipService.shared.block(recipient.id) { err in
            if let err = err {
                print("❌ block error: \(err.localizedDescription)")
                infoToast = "Couldn’t block."
                return
            }
            infoToast = "Blocked."
            refreshGate(andAttachListener: false)
        }
    }

    private func unblockUser() {
        DMRelationshipService.shared.unblock(recipient.id) { err in
            if let err = err {
                print("❌ unblock error: \(err.localizedDescription)")
                infoToast = "Couldn’t unblock."
                return
            }
            infoToast = "Unblocked."
            refreshGate(andAttachListener: true)
        }
    }

    // MARK: - Send (request-aware)

    private func sendTapped(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch gate {
        case .accepted:
            actuallySendText(trimmed)
        case .needsRequest, .requestSent:
            sendRequest(trimmed)
        case .requestFromThem:
            infoToast = "Accept the request to start chatting."
        case .blockedByMe:
            infoToast = "Unblock to send messages."
        case .blockedByThem:
            infoToast = "This user isn’t receiving messages from you."
        }
    }

    private func sendRequest(_ text: String) {
        guard let me = meProfile else {
            infoToast = "Loading your profile… try again."
            loadMeProfile()
            return
        }
        DMRelationshipService.shared.sendRequest(to: recipient, firstText: text, meProfile: me) { err in
            if let err = err {
                print("❌ sendRequest error: \(err.localizedDescription)")
                infoToast = "Couldn’t send request."
                return
            }
            messageText = ""
            infoToast = "Request sent."
            refreshGate(andAttachListener: false)
        }
    }

    private func actuallySendText(_ text: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let chatRef = Firestore.firestore().collection("directChats").document(chatId)
        let messageData: [String: Any] = [
            "text": text,
            "senderId": uid,
            "recipientId": recipient.id,
            "type": "text",
            "timestamp": Timestamp(),
            "edited": editingMessageId != nil
        ]

        chatRef.setData([
            "lastMessageTimestamp": FieldValue.serverTimestamp(),
            "lastMessageSender": uid
        ], merge: true)

        if let messageId = editingMessageId {
            chatRef.collection("messages").document(messageId).updateData(messageData)
            editingMessageId = nil
        } else {
            chatRef.collection("messages").addDocument(data: messageData)
        }

        chatRef.collection("readStatus").document(uid).setData([
            "lastSeen": FieldValue.serverTimestamp()
        ], merge: true)

        sendDirectChatNotification(to: recipient, text: text)
        messageText = ""
    }

    // MARK: - Media

    private func handlePickedMedia(_ item: PhotosPickerItem) async {
        guard gate == .accepted else {
            infoToast = "They must accept before you can send media."
            selectedMediaItem = nil
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let fileExt = item.supportedContentTypes.first?.preferredFilenameExtension else {
                selectedMediaItem = nil
                return
            }
            let filename = UUID().uuidString + ".\(fileExt)"
            let ref = Storage.storage().reference().child("chat_media/\(filename)")
            _ = try await ref.putDataAsync(data)
            let url = try await ref.downloadURL()

            let type: String
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                type = "video"
            } else if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                type = "image"
            } else {
                selectedMediaItem = nil
                return
            }
            sendMediaMessage(url: url.absoluteString, type: type)
        } catch {
            print("❌ Media upload failed: \(error.localizedDescription)")
            infoToast = "Media upload failed."
        }
        selectedMediaItem = nil
    }

    private func sendMediaMessage(url: String, type: String) {
        guard gate == .accepted else {
            infoToast = "They must accept before you can send media."
            return
        }
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let chatRef = Firestore.firestore().collection("directChats").document(chatId)
        let messageData: [String: Any] = [
            "type": type,
            "mediaURL": url,
            "senderId": uid,
            "recipientId": recipient.id,
            "timestamp": Timestamp()
        ]
        chatRef.collection("messages").addDocument(data: messageData)

        chatRef.collection("readStatus").document(uid).setData([
            "lastSeen": FieldValue.serverTimestamp()
        ], merge: true)

        let preview = (type == "image") ? "📷 Photo" : "🎥 Video"
        sendDirectChatNotification(to: recipient, text: preview)
    }

    // MARK: - Notification

    private func sendDirectChatNotification(to recipient: ChatUserProfile, text: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let payload: [String: Any] = [
            "recipientId": recipient.id,
            "message": text,
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

    // MARK: - Message delete

    private func deleteMessage(_ msg: ChatMessage) {
        guard let docId = msg.documentId else { return }
        Firestore.firestore()
            .collection("directChats")
            .document(chatId)
            .collection("messages")
            .document(docId)
            .delete()
    }
}

// MARK: - Subviews

private struct GateBannerView: View {
    let loading: Bool
    let gate: DMGateState
    let recipientName: String
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onBlock: () -> Void

    var body: some View {
        Group {
            if loading {
                HStack {
                    ProgressView()
                    Text("Checking conversation permissions…").foregroundColor(.white)
                    Spacer()
                }
                .padding()
                .background(Color.gray.opacity(0.25))
            } else {
                switch gate {
                case .accepted:
                    EmptyView()
                case .requestFromThem:
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.badge").foregroundColor(.yellow)
                        Text("\(recipientName) wants to chat with you.")
                            .foregroundColor(.white)
                        Spacer()
                        Button("Block", role: .destructive) { onBlock() }
                        Button("Decline") { onDecline() }
                        Button("Accept") { onAccept() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.15))
                case .needsRequest:
                    info("Send a message to send a request. They must accept before replying.")
                case .requestSent:
                    info("Request sent. Waiting for \(recipientName) to accept.")
                case .blockedByMe:
                    info("You’ve blocked this user. Unblock to resume the conversation.")
                case .blockedByThem:
                    info("This user isn’t receiving messages from you.")
                }
            }
        }
    }

    private func info(_ text: String) -> some View {
        Text(text)
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.25))
    }
}

private struct MessageListView: View {
    let messages: [ChatMessage]
    let recipientName: String
    var onEdit: (ChatMessage) -> Void
    var onDelete: (ChatMessage) -> Void

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        DirectMessageBubble(
                            message: message,
                            onEdit: onEdit,
                            onDelete: onDelete
                        )
                        .id(message.id)
                        .frame(maxWidth: .infinity, alignment: message.isSender ? .trailing : .leading)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
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
}

private struct ComposerView: View {
    let gate: DMGateState
    @Binding var messageText: String
    @Binding var selectedMediaItem: PhotosPickerItem?
    var onSend: (String) -> Void
    var onPickMedia: (PhotosPickerItem) -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField(placeholderText, text: $messageText, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(Color.gray.opacity(0.25))
                .cornerRadius(20)
                .foregroundColor(.white)
                .disabled(composerDisabled)

            PhotosPicker(
                selection: $selectedMediaItem,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                Image(systemName: "paperclip.circle.fill")
                    .foregroundColor(mediaButtonColor)
                    .font(.title2)
            }
            .disabled(!canSendMedia)
            .onChange(of: selectedMediaItem) { newItem in
                guard let item = newItem else { return }
                if canSendMedia { onPickMedia(item) }
                else { selectedMediaItem = nil }
            }

            Button {
                let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                onSend(text)
            } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(sendButtonColor)
                    .padding(10)
            }
            .disabled(sendDisabled)
        }
    }

    private var composerDisabled: Bool {
        switch gate {
        case .blockedByMe, .blockedByThem, .requestFromThem: return true
        default: return false
        }
    }
    private var canSendMedia: Bool { gate == .accepted }
    private var sendDisabled: Bool {
        switch gate {
        case .blockedByMe, .blockedByThem, .requestFromThem: return true
        default: return messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private var sendButtonColor: Color { sendDisabled ? .gray : .blue }
    private var mediaButtonColor: Color { canSendMedia ? .gray : .gray.opacity(0.4) }
    private var placeholderText: String {
        switch gate {
        case .accepted:       return "Message…"
        case .needsRequest:   return "Send a message request…"
        case .requestSent:    return "Request sent…"
        case .requestFromThem:return "Accept to reply…"
        case .blockedByMe:    return "You’ve blocked this user"
        case .blockedByThem:  return "You can’t message this user"
        }
    }
}

// MARK: - DirectMessageBubble (simple + fast to compile)

private struct DirectMessageBubble: View {
    let message: ChatMessage
    var onEdit: (ChatMessage) -> Void
    var onDelete: (ChatMessage) -> Void

    var body: some View {
        VStack(alignment: message.isSender ? .trailing : .leading, spacing: 6) {
            if let text = message.text, !text.isEmpty {
                Text(text + (message.edited ? " (edited)" : ""))
                    .padding(12)
                    .foregroundColor(.white)
                    .background(message.isSender ? Color.black : Color(red: 127/255, green: 0/255, blue: 255/255))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if let mediaURL = message.mediaURL, let url = URL(string: mediaURL) {
                if message.type == "image" {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: { ProgressView() }
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if message.type == "video" {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            if message.isSender {
                HStack(spacing: 16) {
                    Button { onEdit(message) }  label: { Image(systemName: "pencil").font(.caption) }
                    Button { onDelete(message) } label: { Image(systemName: "trash").font(.caption) }
                }
                .foregroundColor(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isSender ? .trailing : .leading)
    }
}
