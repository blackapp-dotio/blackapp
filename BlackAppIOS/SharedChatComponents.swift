// SharedChatComponents.swift (fully aligned with SharedModels.swift)

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

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
    @State private var showUserPicker = false

    var body: some View {
        NavigationStack {
            List(users) { user in
                NavigationLink(destination: DirectChatRoomView(recipient: user)) {
                    Text(user.name)
                        .foregroundColor(.white)
                }
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
                    self.selectedRecipient = selectedUser
                }
            }
            .navigationDestination(isPresented: .constant(selectedRecipient != nil)) {
                if let recipient = selectedRecipient {
                    DirectChatRoomView(recipient: recipient)
                }
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
                guard let name = data["name"] as? String, let username = data["username"] as? String else { return nil }
                return ChatUserProfile(id: id, name: name, username: username)
            } ?? []
        }
    }
}


// MARK: - GroupChatListView

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

// MARK: - MessageBubbleView

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        Text(message.text)
            .padding(12)
            .background(message.isSender ? Color.black : Color.white)
            .foregroundColor(message.isSender ? .white : .black)
            .clipShape(WaterDropShape(isSender: message.isSender))
            .animation(.easeInOut, value: message.text)
    }
}

// MARK: - DirectChatRoomView

struct DirectChatRoomView: View {
    var recipient: ChatUserProfile
    @State private var messageText: String = ""
    @State private var messages: [ChatMessage] = []

    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .frame(maxWidth: .infinity, alignment: message.isSender ? .trailing : .leading)
                            .padding(.horizontal)
                    }
                }
                .padding(.top)
            }

            HStack {
                TextField("Message...", text: $messageText)
                    .padding(10)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(20)
                    .foregroundColor(.white)

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
        .background(Color.black.ignoresSafeArea())
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

                messages = documents.compactMap { doc in
                    let data = doc.data()
                    let text = data["text"] as? String ?? ""
                    let senderId = data["senderId"] as? String ?? ""
                    return ChatMessage(text: text, isSender: senderId == Auth.auth().currentUser?.uid)
                }
            }
    }

    func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        let messageData: [String: Any] = [
            "text": messageText,
            "senderId": uid,
            "timestamp": Timestamp()
        ]

        Firestore.firestore().collection("directChats").document(chatId).collection("messages").addDocument(data: messageData)

        messageText = ""
    }
}

// MARK: - GroupChatRoomView

struct GroupChatRoomView: View {
    var group: GroupChat
    @State private var messageText: String = ""
    @State private var messages: [ChatMessage] = []

    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .frame(maxWidth: .infinity, alignment: message.isSender ? .trailing : .leading)
                            .padding(.horizontal)
                    }
                }
                .padding(.top)
            }

            HStack {
                TextField("Message...", text: $messageText)
                    .padding(10)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(20)
                    .foregroundColor(.white)

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.blue)
                        .padding(10)
                }
            }
            .padding()
            .background(Color.black)
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black.ignoresSafeArea())
        .onAppear(perform: loadMessages)
    }

    func loadMessages() {
        Firestore.firestore().collection("groupChats").document(group.id).collection("messages")
            .order(by: "timestamp")
            .addSnapshotListener { snapshot, error in
                guard let documents = snapshot?.documents else { return }

                messages = documents.compactMap { doc in
                    let data = doc.data()
                    let text = data["text"] as? String ?? ""
                    let senderId = data["senderId"] as? String ?? ""
                    return ChatMessage(text: text, isSender: senderId == Auth.auth().currentUser?.uid)
                }
            }
    }

    func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty,
              let uid = Auth.auth().currentUser?.uid else { return }

        let messageData: [String: Any] = [
            "text": messageText,
            "senderId": uid,
            "timestamp": Timestamp()
        ]

        Firestore.firestore().collection("groupChats").document(group.id).collection("messages").addDocument(data: messageData)

        messageText = ""
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
                    Text(user.name)
                        .foregroundColor(.white)
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
                print("❌ Error: \(error.localizedDescription)")
                return
            }

            users = snapshot?.documents.compactMap { doc in
                let data = doc.data()
                let id = doc.documentID
                guard id != currentUid else { return nil }
                guard let name = data["name"] as? String,
                      let username = data["username"] as? String else { return nil }
                return ChatUserProfile(id: id, name: name, username: username)
            } ?? []
        }
    }
}
