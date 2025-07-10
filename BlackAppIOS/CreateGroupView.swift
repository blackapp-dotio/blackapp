import SwiftUI
import Firebase
import FirebaseFirestore
import FirebaseAuth
import FirebaseStorage
import PhotosUI

struct CreateGroupView: View {
   @Environment(\.dismiss) var dismiss
   
   @State private var groupName: String = ""
   @State private var groupDescription: String = ""
   @State private var coverImage: UIImage? = nil
   @State private var coverImageItem: PhotosPickerItem? = nil
   @State private var coverImageURL: String? = nil
   @State private var isCreating = false
   
   
   var body: some View {
       NavigationStack {
           VStack(spacing: 20) {
               TextField("Group Name", text: $groupName)
                   .padding()
                   .background(Color.gray.opacity(0.2))
                   .cornerRadius(8)
                   .foregroundColor(.white)
               
               TextField("Group Description", text: $groupDescription)
                   .padding()
                   .background(Color.gray.opacity(0.2))
                   .cornerRadius(8)
                   .foregroundColor(.white)
               
               VStack(alignment: .leading) {
                   Text("Group Cover Image")
                       .foregroundColor(.gray)
                   
                   if let image = coverImage {
                       Image(uiImage: image)
                           .resizable()
                           .scaledToFit()
                           .frame(height: 150)
                           .cornerRadius(10)
                   }
                   
                   PhotosPicker(selection: $coverImageItem, matching: .images) {
                       Text("Choose Cover Image")
                           .padding()
                           .background(Color.gray.opacity(0.2))
                           .cornerRadius(8)
                   }
                   .onChange(of: coverImageItem) { newItem in
                       if let newItem {
                           Task {
                               if let data = try? await newItem.loadTransferable(type: Data.self),
                                  let uiImage = UIImage(data: data) {
                                   self.coverImage = uiImage
                                   uploadCoverImage(uiImage)
                               }
                           }
                       }
                   }
               }
               
               Button(action: createGroup) {
                   Text("Create Group")
                       .frame(maxWidth: .infinity)
                       .padding()
                       .background(isCreating ? Color.gray : Color.blue)
                       .cornerRadius(10)
                       .foregroundColor(.white)
               }
               .disabled(isCreating || groupName.isEmpty)
           }
           .padding()
           .background(Color.black.ignoresSafeArea())
           .navigationTitle("New Group")
       }
   }
   
    func createGroup() {
        guard let currentUserId = Auth.auth().currentUser?.uid else {
            print("❌ No authenticated user.")
            return
        }

        isCreating = true
        let groupId = UUID().uuidString

        let groupData: [String: Any] = [
            "name": groupName,
            "description": groupDescription,
            "members": [currentUserId], // ✅ Original fetch logic needs this
            "adminIds": [currentUserId],
            "ownerId": currentUserId,
            "coverImageURL": coverImageURL ?? "",
            "createdAt": FieldValue.serverTimestamp()
        ]

        let db = Firestore.firestore()

        // Save to original "groups" collection
        db.collection("groups").document(groupId).setData(groupData) { error in
            if let error = error {
                print("❌ Failed to create group: \(error.localizedDescription)")
                isCreating = false
                return
            }

            // ✅ Also add to members subcollection for OneSignal support
            db.collection("groups").document(groupId).collection("members").document(currentUserId).setData([
                "joinedAt": FieldValue.serverTimestamp(),
                "role": "admin"
            ]) { error in
                isCreating = false
                if let error = error {
                    print("⚠️ Group created but failed to add to members subcollection: \(error.localizedDescription)")
                } else {
                    print("✅ Group created with member subcollection.")
                }
                dismiss()
            }
        }
    }

   func uploadCoverImage(_ image: UIImage) {
       guard let imageData = image.jpegData(compressionQuality: 0.8) else { return }
       let filename = UUID().uuidString + ".jpg"
       let ref = Storage.storage().reference().child("group_covers/\(filename)")
       
       ref.putData(imageData, metadata: nil) { _, error in
           if let error = error {
               print("❌ Upload failed: \(error.localizedDescription)")
               return
           }
           
           ref.downloadURL { url, _ in
               self.coverImageURL = url?.absoluteString
               print("✅ Cover image uploaded: \(self.coverImageURL ?? "none")")
           }
       }
   }
}

