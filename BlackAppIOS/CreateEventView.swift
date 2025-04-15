import SwiftUI
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage

struct CreateEventView: View {
    @Environment(\.presentationMode) var presentationMode

    @State private var eventName = ""
    @State private var eventDescription = ""
    @State private var eventDate = Date()
    @State private var location = ""
    @State private var eventImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var isSubmitting = false

    @State private var ticketPrice = ""
    @State private var ticketQuantity = ""
    @State private var tablePrice = ""
    @State private var tableQuantity = ""
    @State private var paymentLink = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Create New Event")
                        .font(.title)
                        .bold()

                    Group {
                        TextField("Event Name", text: $eventName)
                        TextField("Location", text: $location)
                        TextEditor(text: $eventDescription)
                            .frame(height: 100)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray))
                        DatePicker("Event Date & Time", selection: $eventDate)
                    }

                    Group {
                        TextField("Ticket Price (USD)", text: $ticketPrice)
                            .keyboardType(.decimalPad)
                        TextField("Number of Tickets", text: $ticketQuantity)
                            .keyboardType(.numberPad)
                        TextField("Table Price (USD)", text: $tablePrice)
                            .keyboardType(.decimalPad)
                        TextField("Number of Tables", text: $tableQuantity)
                            .keyboardType(.numberPad)
                        TextField("Payment Link (Optional)", text: $paymentLink)
                    }

                    if let image = eventImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 200)
                            .cornerRadius(12)
                    }

                    Button("Upload Event Image") {
                        showImagePicker = true
                    }

                    Button(action: createEvent) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Publish Event")
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
            .navigationTitle("Create Event")
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $eventImage)
            }
        }
        .preferredColorScheme(.dark)
    }

    func createEvent() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        guard !eventName.isEmpty, !eventDescription.isEmpty else { return }

        isSubmitting = true

        let eventId = UUID().uuidString
        let timestamp = Date().timeIntervalSince1970
        let dateValue = eventDate.timeIntervalSince1970

        func saveEvent(imageURL: String?) {
            let ref = Database.database().reference().child("events").child(eventId)
            let data: [String: Any] = [
                "id": eventId,
                "name": eventName,
                "description": eventDescription,
                "timestamp": timestamp,
                "date": dateValue,
                "location": location,
                "ticketPrice": ticketPrice,
                "ticketQuantity": ticketQuantity,
                "tablePrice": tablePrice,
                "tableQuantity": tableQuantity,
                "paymentLink": paymentLink,
                "imageURL": imageURL as Any,
                "userId": userId
            ]
            ref.setValue(data) { error, _ in
                isSubmitting = false
                if error == nil {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }

        if let image = eventImage, let imageData = image.jpegData(compressionQuality: 0.8) {
            let storageRef = Storage.storage().reference().child("event_images/\(eventId).jpg")
            storageRef.putData(imageData) { _, error in
                if error != nil {
                    isSubmitting = false
                    return
                }
                storageRef.downloadURL { url, _ in
                    saveEvent(imageURL: url?.absoluteString)
                }
            }
        } else {
            saveEvent(imageURL: nil)
        }
    }
}
