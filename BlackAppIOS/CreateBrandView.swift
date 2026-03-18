// CreateBrandView.swift — Brand applications with required logo + detailed intent

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
    @State private var description: String = ""              // Short brand overview
    @State private var brandPurpose: String = ""             // Why does this brand exist?
    @State private var usagePlan: String = ""                // How will they use BlackApp?
    @State private var businessCategory: String = ""         // What kind of business?

    @State private var logoImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var isSaving = false
    @State private var errorText: String?

    // Simple length guard to encourage more detailed answers
    private let minTextLength = 30

    private var canSubmit: Bool {
        let nameOK = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let descOK = description.trimmingCharacters(in: .whitespacesAndNewlines).count >= minTextLength
        let purposeOK = brandPurpose.trimmingCharacters(in: .whitespacesAndNewlines).count >= minTextLength
        let usageOK = usagePlan.trimmingCharacters(in: .whitespacesAndNewlines).count >= minTextLength
        let categoryOK = !businessCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let logoOK = (logoImage != nil)

        return nameOK && descOK && purposeOK && usageOK && categoryOK && logoOK && !isSaving
    }

    var body: some View {
        NavigationView {
            Form {
                // MARK: Brand basics
                Section(header: Text("Brand Info")) {
                    TextField("Brand Name", text: $name)
                        .autocapitalization(.words)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Short Description")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextEditor(text: $description)
                            .frame(height: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.6))
                            )

                        Text("Tell us what your brand is about. At least \(minTextLength) characters.")
                            .font(.caption2)
                            .foregroundColor(description.count >= minTextLength ? .green : .red)
                    }
                }

                // MARK: Application details for admin screening
                Section(header: Text("Application Details")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Purpose of the Brand")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextEditor(text: $brandPurpose)
                            .frame(height: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.6))
                            )

                        Text("Explain why this brand exists and what makes it unique. At least \(minTextLength) characters.")
                            .font(.caption2)
                            .foregroundColor(brandPurpose.count >= minTextLength ? .green : .red)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("How Will You Use BlackApp?")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextEditor(text: $usagePlan)
                            .frame(height: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.6))
                            )

                        Text("Describe the type of events, services, content, or nightlife business you’ll bring to the platform. At least \(minTextLength) characters.")
                            .font(.caption2)
                            .foregroundColor(usagePlan.count >= minTextLength ? .green : .red)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Business Category / Type")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("e.g. Nightclub, Lounge, Clothing Brand, Podcast, Promoter, etc.", text: $businessCategory)

                        Text("This helps admins quickly understand what lane your brand fits in.")
                            .font(.caption2)
                            .foregroundColor(businessCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .red : .green)
                    }
                }

                // MARK: Logo upload (required)
                Section(header: Text("Logo (Required)")) {
                    if let image = logoImage {
                        VStack(spacing: 8) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            Button("Change Logo") {
                                showImagePicker = true
                            }
                            .font(.subheadline)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                showImagePicker = true
                            } label: {
                                HStack {
                                    Image(systemName: "photo.on.rectangle.angled")
                                    Text("Upload Brand Logo")
                                }
                            }

                            Text("A clear logo is required before your brand can be reviewed.")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                }

                // MARK: Submit section
                Section {
                    Button(action: saveBrand) {
                        if isSaving {
                            HStack {
                                ProgressView()
                                Text("Submitting Application…")
                            }
                        } else {
                            Text("Submit Brand Application")
                        }
                    }
                    .disabled(!canSubmit)
                } footer: {
                    Text("Brand applications are reviewed by BlackApp admins. Incomplete or low-detail applications may be rejected.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Create Brand")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $logoImage)
            }
            .alert("Error", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Save Brand

    private func saveBrand() {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorText = "You must be signed in to create a brand."
            return
        }
        guard let image = logoImage,
              let imageData = image.jpegData(compressionQuality: 0.8) else {
            errorText = "Logo image is required."
            return
        }

        isSaving = true
        errorText = nil

        let brandId = UUID().uuidString
        let storageRef = Storage.storage().reference().child("brand_logos/\(brandId).jpg")

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        print("🚀 Starting brand application save…")
        print("⬆️ Uploading logo image to Firebase Storage for brand \(brandId)…")

        storageRef.putData(imageData, metadata: metadata) { _, error in
            if let error = error {
                print("❌ Logo upload failed: \(error.localizedDescription)")
                self.errorText = "Logo upload failed. Please try again."
                self.isSaving = false
                return
            }

            storageRef.downloadURL { url, _ in
                guard let downloadURL = url else {
                    print("❌ Failed to obtain logo download URL")
                    self.errorText = "Could not get logo URL. Please try again."
                    self.isSaving = false
                    return
                }

                print("✅ Logo uploaded. URL: \(downloadURL.absoluteString)")
                print("📡 Saving brand application to Realtime Database…")

                let brandRef = Database.database().reference().child("brands").childByAutoId()

                let now = ServerValue.timestamp()

                let brandData: [String: Any] = [
                    "id": brandRef.key ?? brandId,
                    "name": self.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "description": self.description.trimmingCharacters(in: .whitespacesAndNewlines),

                    // Admin-facing application details
                    "applicationPurpose": self.brandPurpose.trimmingCharacters(in: .whitespacesAndNewlines),
                    "applicationUsagePlan": self.usagePlan.trimmingCharacters(in: .whitespacesAndNewlines),
                    "businessCategory": self.businessCategory.trimmingCharacters(in: .whitespacesAndNewlines),

                    "logoURL": downloadURL.absoluteString,
                    "ownerId": uid,

                    // Review / moderation flags
                    "approved": false,
                    "suspended": false,
                    "status": "pending_review",

                    // Timestamps
                    "createdAt": now,
                    "updatedAt": now
                ]

                brandRef.setValue(brandData) { error, _ in
                    self.isSaving = false
                    if let error = error {
                        print("❌ Failed to save brand: \(error.localizedDescription)")
                        self.errorText = "Could not save brand: \(error.localizedDescription)"
                    } else {
                        print("✅ Brand application saved successfully at node: \(brandRef.key ?? "")")
                        self.presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
