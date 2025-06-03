// MARK: - UserPickerView

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import UniformTypeIdentifiers
import AVKit

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
