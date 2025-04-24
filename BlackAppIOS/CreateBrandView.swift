import SwiftUI
import Firebase
import FirebaseStorage
import FirebaseDatabase
import FirebaseAuth

struct CreateBrandView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var name = ""
    @State private var description = ""
    @State private var logoImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var isSubmitting = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Create Your Brand")
                        .font(.title)
                        .bold()

                    TextField("Brand Name", text: $name)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    TextEditor(text: $description)
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray))

                    if let logo = logoImage {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 200)
                            .cornerRadius(12)
                    }

                    Button("Upload Logo") {
                        showImagePicker = true
                    }

                    Button(action: createBrand) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Submit for Approval")
                                .bold()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding()
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $logoImage)
            }
            .preferredColorScheme(.dark)
        }
    }

    func createBrand() {
        guard !name.isEmpty, !description.isEmpty, let userId = Auth.auth().currentUser?.uid else {
            print("Validation failed or user not authenticated")
            return
        }

        isSubmitting = true
        let brandId = UUID().uuidString
        let timestamp = Date().timeIntervalSince1970

        func saveToDatabase(logoURL: String?) {
            let ref = Database.database().reference().child("brands").child(brandId)
            let brandData: [String: Any] = [
                "id": brandId,
                "ownerId": userId, // 🔑 Important: must match BrandModel
                "name": name,
                "description": description,
                "timestamp": timestamp,
                "logoURL": logoURL as Any,
                "approved": false
            ]

            ref.setValue(brandData) { error, _ in
                isSubmitting = false
                if let error = error {
                    print("Failed to save brand: \(error.localizedDescription)")
                } else {
                    print("✅ Brand saved successfully")
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }

        if let image = logoImage, let imageData = image.jpegData(compressionQuality: 0.8) {
            let storageRef = Storage.storage().reference().child("brand_logos/\(brandId).jpg")
            storageRef.putData(imageData, metadata: nil) { _, error in
                if let error = error {
                    print("Image upload error: \(error.localizedDescription)")
                    isSubmitting = false
                    return
                }
                storageRef.downloadURL { url, _ in
                    saveToDatabase(logoURL: url?.absoluteString)
                }
            }
        } else {
            saveToDatabase(logoURL: nil)
        }
    }
}
