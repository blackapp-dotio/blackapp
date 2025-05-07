// CreateGroupChatView.swift (aligned with SharedModels.swift and SharedChatComponents.swift)

import SwiftUI
import FirebaseFirestore
import FirebaseAuth

struct CreateGroupChatView: View {
    @Environment(\.dismiss) var dismiss
    @State private var groupName: String = ""
    @State private var allUsers: [ChatUserProfile] = []
    @State private var selectedUserIds: Set<String> = []
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Create a New Group")
                .font(.title2)
                .bold()
                .foregroundColor(.white)

            TextField("Group Name", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Text("Select Members:")
                .foregroundColor(.white)
                .padding(.horizontal)

            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(allUsers) { user in
                        Button(action: {
                            if selectedUserIds.contains(user.id) {
                                selectedUserIds.remove(user.id)
                            } else {
                                selectedUserIds.insert(user.id)
                            }
                        }) {
                            HStack {
                                Image(systemName: selectedUserIds.contains(user.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedUserIds.contains(user.id) ? .green : .gray)
                                Text(user.name)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal)
            }

            Button(action: createGroup) {
                HStack {
                    if isSaving {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text("Create Group")
                        .bold()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top)
        .onAppear(perform: loadUsers)
        .background(Color.black.ignoresSafeArea())
    }

    func loadUsers() {
        guard let currentUid = Auth.auth().currentUser?.uid else { return }

        Firestore.firestore().collection("users").getDocuments { snapshot, error in
            if let error = error {
                print("❌ Failed to fetch users: \(error.localizedDescription)")
                return
            }

            allUsers = snapshot?.documents.compactMap { doc in
                let data = doc.data()
                let id = doc.documentID
                guard id != currentUid else { return nil }
                guard let name = data["name"] as? String, let username = data["username"] as? String else { return nil }
                return ChatUserProfile(id: id, name: name, username: username)
            } ?? []
        }
    }

    func createGroup() {
        guard !groupName.isEmpty, !selectedUserIds.isEmpty,
              let currentUid = Auth.auth().currentUser?.uid else { return }

        isSaving = true

        let groupData: [String: Any] = [
            "name": groupName,
            "members": Array(selectedUserIds.union([currentUid])),
            "createdAt": Timestamp()
        ]

        Firestore.firestore().collection("groups").addDocument(data: groupData) { error in
            isSaving = false
            if let error = error {
                print("❌ Error creating group: \(error.localizedDescription)")
                return
            }
            print("✅ Group '\(groupName)' created successfully.")
            dismiss()
        }
    }
}
