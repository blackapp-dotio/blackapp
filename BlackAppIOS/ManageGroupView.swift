import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore

struct GroupMember: Identifiable {
    let id: String
    var role: String
    var displayName: String?
}

struct ManageGroupView: View {
    var group: GroupChat

    @Environment(\.dismiss) var dismiss
    @State private var members: [GroupMember] = []
    @State private var newMemberId: String = ""
    @State private var currentUserId: String = Auth.auth().currentUser?.uid ?? ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var allUsers: [ChatUserProfile] = []
    @State private var suggestedUsers: [ChatUserProfile] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isLoading {
                    ProgressView("Loading members...")
                        .padding()
                } else {
                    if members.isEmpty {
                        Text("No members yet.")
                            .foregroundColor(.gray)
                    } else {
                        List {
                            ForEach(members) { member in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(member.displayName ?? member.id)
                                            .font(.callout)
                                            .foregroundColor(.white)
                                        Text(member.role.capitalized)
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()

                                    if currentUserIsAdmin && member.id != currentUserId {
                                        Menu {
                                            if member.role != "admin" {
                                                Button("Promote to Admin") {
                                                    updateRole(for: member, to: "admin")
                                                }
                                            } else {
                                                Button("Demote to Member") {
                                                    updateRole(for: member, to: "member")
                                                }
                                            }
                                            Button("Remove from Group", role: .destructive) {
                                                removeMember(member)
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .foregroundColor(.white)
                                                .font(.title2)
                                                .padding(.horizontal, 8)
                                        }
                                    }
                                }
                                .listRowBackground(Color.black)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color.black)

                        Divider()

                        if currentUserIsAdmin {
                            VStack(spacing: 8) {
                                TextField("Search users by name or ID", text: $newMemberId)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                    .onChange(of: newMemberId) { query in
                                        searchUsers(query: query)
                                    }

                                if !suggestedUsers.isEmpty {
                                    ScrollView(.horizontal) {
                                        HStack {
                                            ForEach(suggestedUsers, id: \.id) { user in
                                                Button(action: {
                                                    newMemberId = user.id
                                                }) {
                                                    Text(user.name)
                                                        .padding(6)
                                                        .background(Color.gray.opacity(0.3))
                                                        .cornerRadius(6)
                                                }
                                            }
                                        }
                                    }
                                }

                                Button("Add Member") {
                                    addMember()
                                }
                                .disabled(newMemberId.isEmpty)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                            .padding()
                        }

                        if let errorMessage = errorMessage {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.footnote)
                                .padding(.horizontal)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Manage Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                fetchMembers()
                fetchAllUsers()
            }
        }
    }

    var currentUserIsAdmin: Bool {
        return group.adminIds.contains(currentUserId) || group.ownerId == currentUserId
    }

    func fetchMembers() {
        isLoading = true
        let db = Firestore.firestore()
        let groupRef = db.collection("groups").document(group.id)

        groupRef.collection("members").getDocuments { snapshot, error in
            isLoading = false
            if let error = error {
                errorMessage = "Failed to load members: \(error.localizedDescription)"
                return
            }

            var fetched: [GroupMember] = snapshot?.documents.map { doc -> GroupMember in
                let data = doc.data()
                let id = doc.documentID
                let role = data["role"] as? String ?? "member"
                return GroupMember(id: id, role: role, displayName: nil)
            } ?? []

            let userIds = fetched.map { $0.id }
            guard !userIds.isEmpty else {
                self.members = fetched
                return
            }

            db.collection("users").whereField(FieldPath.documentID(), in: userIds).getDocuments { userSnapshot, _ in
                var updatedMembers = fetched
                if let userDocs = userSnapshot?.documents {
                    for i in 0..<updatedMembers.count {
                        if let match = userDocs.first(where: { $0.documentID == updatedMembers[i].id }) {
                            updatedMembers[i].displayName = match.data()["name"] as? String
                        }
                    }
                }
                self.members = updatedMembers
            }
        }
    }

    func fetchAllUsers() {
        Firestore.firestore().collection("users").getDocuments { snapshot, error in
            if let documents = snapshot?.documents {
                self.allUsers = documents.map { doc in
                    let data = doc.data()
                    let id = doc.documentID
                    let name = data["name"] as? String ?? "Unnamed"
                    let username = data["username"] as? String ?? ""
                    return ChatUserProfile(id: id, name: name, username: username, profileImageURL: nil)
                }
            }
        }
    }

    func searchUsers(query: String) {
        if query.isEmpty {
            suggestedUsers = []
        } else {
            suggestedUsers = allUsers.filter {
                $0.name.lowercased().contains(query.lowercased()) ||
                $0.username.lowercased().contains(query.lowercased()) ||
                $0.id.lowercased().contains(query.lowercased())
            }
        }
    }

    func updateRole(for member: GroupMember, to newRole: String) {
        Firestore.firestore()
            .collection("groups")
            .document(group.id)
            .collection("members")
            .document(member.id)
            .updateData(["role": newRole]) { error in
                if let error = error {
                    errorMessage = "Failed to update role: \(error.localizedDescription)"
                } else {
                    fetchMembers()
                }
            }

        let groupRef = Firestore.firestore().collection("groups").document(group.id)
        if newRole == "admin" {
            groupRef.updateData(["adminIds": FieldValue.arrayUnion([member.id])])
        } else {
            groupRef.updateData(["adminIds": FieldValue.arrayRemove([member.id])])
        }
    }

    func removeMember(_ member: GroupMember) {
        Firestore.firestore()
            .collection("groups")
            .document(group.id)
            .collection("members")
            .document(member.id)
            .delete { error in
                if let error = error {
                    errorMessage = "Failed to remove member: \(error.localizedDescription)"
                } else {
                    let groupRef = Firestore.firestore().collection("groups").document(group.id)
                    groupRef.updateData([
                        "members": FieldValue.arrayRemove([member.id]),
                        "adminIds": FieldValue.arrayRemove([member.id])
                    ])
                    fetchMembers()
                }
            }
    }

    func addMember() {
        guard let user = allUsers.first(where: { $0.id == newMemberId }) else {
            errorMessage = "Invalid user ID"
            return
        }

        let memberRef = Firestore.firestore()
            .collection("groups")
            .document(group.id)
            .collection("members")
            .document(user.id)

        memberRef.setData([
            "role": "member",
            "joinedAt": FieldValue.serverTimestamp()
        ]) { error in
            if let error = error {
                errorMessage = "Failed to add member: \(error.localizedDescription)"
            } else {
                let groupRef = Firestore.firestore().collection("groups").document(group.id)
                groupRef.updateData(["members": FieldValue.arrayUnion([user.id])])
                newMemberId = ""
                fetchMembers()
            }
        }
    }
}
