// CreateBrandView.swift (Fixed EnvironmentObject and Auth access)

import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseStorage
import FirebaseDatabase
import PhotosUI

struct CreateBrandView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var authVM: AuthViewModel

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var logoImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var isSaving = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Brand Info")) {
                    TextField("Brand Name", text: $name)
                    TextEditor(text: $description)
                        .frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray))
                }

                Section(header: Text("Logo")) {
                    if let image = logoImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 100)
                    } else {
                        Button("Upload Logo") {
                            showImagePicker = true
                        }
                    }
                }

                Section {
                    Button(action: saveBrand) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Create Brand")
                        }
                    }
                    .disabled(name.isEmpty || description.isEmpty || logoImage == nil)
                }
            }
            .navigationTitle("Create Brand")
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $logoImage)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func saveBrand() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard let image = logoImage,
              let imageData = image.jpegData(compressionQuality: 0.8) else { return }

        isSaving = true
        let brandId = UUID().uuidString
        let storageRef = Storage.storage().reference().child("brand_logos/\(brandId).jpg")

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        print("🚀 Starting brand save process...")
        print("⬆️ Uploading logo image to Firebase Storage...")

        storageRef.putData(imageData, metadata: metadata) { _, error in
            guard error == nil else {
                print("❌ Upload failed: \(error!.localizedDescription)")
                isSaving = false
                return
            }

            storageRef.downloadURL { url, _ in
                guard let downloadURL = url else {
                    print("❌ Failed to get download URL")
                    isSaving = false
                    return
                }

                print("✅ Logo uploaded. Download URL: \(downloadURL.absoluteString)")
                print("📡 Saving brand to database...")

                let brandRef = Database.database().reference().child("brands").childByAutoId()
                let brandData: [String: Any] = [
                    "name": name,
                    "description": description,
                    "logoURL": downloadURL.absoluteString,
                    "ownerId": uid,
                    "approved": false,
                    "suspended": false
                ]

                brandRef.setValue(brandData) { error, _ in
                    isSaving = false
                    if let error = error {
                        print("❌ Failed to save brand: \(error.localizedDescription)")
                    } else {
                        print("✅ Brand saved successfully at node: \(brandRef.key ?? "")")
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
