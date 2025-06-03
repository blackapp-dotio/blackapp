// MARK: - GroupChatRoomView

import PhotosUI
import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
     
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
                    } else {
                        // Provide a fallback for when there's no cover image
                        Color.gray.frame(height: 160)
                    }

                    // 🟡 Insert the rest of your view content here.
                    // For example:
                    Text("Group Chat Content Here...")
                        .foregroundColor(.white)                    }
                
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

    func sendMediaMessage(url: String, type: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        let data: [String: Any] = [
            "type": type,
            "mediaURL": url,
            "senderId": uid,
            "timestamp": Timestamp(),
            "likes": [],
            "comments": [],
            "reposts": []
        ]
        
        let ref = Firestore.firestore().collection("groupChats").document(group.id).collection("messages")
        ref.addDocument(data: data)
    }
}

