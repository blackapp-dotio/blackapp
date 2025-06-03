// import PhotosUI
import PhotosUI
import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

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
                                let ref = Storage.storage().reference().child("chat_media/\(filename)")

                                ref.putData(data, metadata: nil) { _, error in
                                    if let error = error {
                                        print("❌ Upload failed: \(error.localizedDescription)")
                                        return
                                    }

                                    ref.downloadURL { url, _ in
                                        guard let url = url else { return }

                                        let type: String
                                        if newItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                                            type = "video"
                                        } else if newItem.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                                            type = "image"
                                        } else {
                                            type = "unsupported"
                                        }

                                        if type != "unsupported" {
                                            sendMediaMessage(url: url.absoluteString, type: type)
                                        } else {
                                            print("❌ Unsupported media type selected.")
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
