import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseStorage
import FirebaseDatabase
import FeedKit
import WebKit

struct EventModel: Identifiable {
    var id: String
    var title: String
    var description: String
    var imagePath: String
    var date: Date
    var payoutMethod: String
    var payoutDetails: String
    var ticketPrice: Double
    var ticketQuantity: Int
    var tablePrice: Double
    var tableQuantity: Int
    var userId: String
    var location: String

    static func from(snapshot: DataSnapshot) -> EventModel? {
        guard let value = snapshot.value as? [String: Any],
              let title = value["title"] as? String,
              let description = value["description"] as? String,
              let imagePath = value["imagePath"] as? String,
              let timestamp = value["date"] as? TimeInterval,
              let userId = value["userId"] as? String else {
            return nil
        }

        func toDouble(_ val: Any?) -> Double {
            if let d = val as? Double { return d }
            if let i = val as? Int { return Double(i) }
            if let s = val as? String, let d = Double(s) { return d }
            return 0.0
        }

        func toInt(_ val: Any?) -> Int {
            if let i = val as? Int { return i }
            if let s = val as? String, let i = Int(s) { return i }
            if let d = val as? Double { return Int(d) }
            return 0
        }

        return EventModel(
            id: snapshot.key,
            title: title,
            description: description,
            imagePath: imagePath,
            date: Date(timeIntervalSince1970: timestamp),
            payoutMethod: value["payoutMethod"] as? String ?? "",
            payoutDetails: value["payoutDetails"] as? String ?? "",
            ticketPrice: toDouble(value["ticketPrice"]),
            ticketQuantity: toInt(value["ticketQuantity"]),
            tablePrice: toDouble(value["tablePrice"]),
            tableQuantity: toInt(value["tableQuantity"]),
            userId: userId,
            location: value["location"] as? String ?? ""
        )
    }

}

// MARK: - MyEventsView
import SwiftUI
import Firebase

struct MyEventsView: View {
    @State private var myCreatedEvents: [EventModel] = []
    @State private var myPurchasedEvents: [PurchaseModel] = []
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false

    @State private var selectedEventToEdit: EventModel? = nil
    @State private var selectedEventForStats: EventModel? = nil
    @State private var selectedPurchase: PurchaseModel? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Events I've Created")
                        .font(.headline)
                        .padding(.horizontal)

                    ForEach(myCreatedEvents) { event in
                        VStack(alignment: .leading) {
                            EventCardView(event: event)

                            HStack(spacing: 10) {
                                Button("Edit") {
                                    selectedEventToEdit = event
                                }
                                .padding(8)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(8)

                                Button("Delete") {
                                    deleteEvent(event)
                                }
                                .padding(8)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(8)

                                Button("Stats") {
                                    selectedEventForStats = event
                                }
                                .padding(8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                            .padding(.horizontal)
                        }
                    }

                    Divider().padding(.vertical)

                    Text("Events I've Purchased")
                        .font(.headline)
                        .padding(.horizontal)

                    ForEach(myPurchasedEvents) { purchase in
                        VStack(alignment: .leading, spacing: 10) {
                            EventImageView(imagePath: purchase.eventImagePath)
                                .frame(height: 200)
                                .cornerRadius(10)

                            Text(purchase.eventTitle)
                                .font(.headline)

                            Text("Date: \(formattedDate(from: purchase.timestamp))")
                                .font(.subheadline)
                                .foregroundColor(.gray)

                            Button("View Ticket") {
                                selectedPurchase = purchase
                            }
                            .padding(8)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("My Events")
            .onAppear {
                fetchMyEvents()
                fetchMyPurchasedEvents()
            }
            .sheet(item: $selectedEventToEdit) { event in
                EditEventView(event: event)
            }
            .sheet(item: $selectedEventForStats) { event in
                EventStatsView(event: event)
            }
            .sheet(item: $selectedPurchase) { purchase in
                ShowTicketView(purchase: purchase)
            }
            .sheet(isPresented: $showWebView) {
                if let url = selectedURL {
                    WebView(url: url).edgesIgnoringSafeArea(.all)
                }
            }
        }
    }

    private func fetchMyEvents() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("events")

        ref.observeSingleEvent(of: .value) { snapshot in
            var createdEvents: [EventModel] = []

            for child in snapshot.children {
                if let childSnapshot = child as? DataSnapshot,
                   let event = EventModel.from(snapshot: childSnapshot),
                   event.userId == userId {
                    createdEvents.append(event)
                }
            }

            self.myCreatedEvents = createdEvents.sorted { $0.date > $1.date }
        }
    }

    private func fetchMyPurchasedEvents() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(userId)

        ref.observeSingleEvent(of: .value) { snapshot in
            var purchases: [PurchaseModel] = []

            for case let child as DataSnapshot in snapshot.children {
                guard let value = child.value as? [String: Any] else { continue }

                let model = PurchaseModel(
                    id: child.key,
                    userId: value["userId"] as? String ?? "",
                    eventId: value["eventId"] as? String ?? "",
                    eventTitle: value["eventTitle"] as? String ?? "Untitled Event",
                    eventImagePath: value["eventImagePath"] as? String ?? "",
                    quantity: value["quantity"] as? Int ?? 0,
                    type: value["type"] as? String ?? "ticket",
                    totalAmount: value["totalAmount"] as? Double ?? 0.0,
                    timestamp: value["timestamp"] as? TimeInterval ?? 0.0
                )

                purchases.append(model)
            }

            let sortedPurchases = purchases.sorted { $0.timestamp > $1.timestamp }
            self.myPurchasedEvents = sortedPurchases
        }
    }

    private func deleteEvent(_ event: EventModel) {
        let ref = Database.database().reference().child("events").child(event.id)
        ref.removeValue { error, _ in
            if let error = error {
                print("❌ Failed to delete event: \(error.localizedDescription)")
            } else {
                self.myCreatedEvents.removeAll { $0.id == event.id }
            }
        }
    }

    private func formattedDate(from timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

import SwiftUI
import Firebase

struct ShowTicketView: View {
    let purchase: PurchaseModel
    @Environment(\.presentationMode) var presentationMode
    @State private var isCheckedIn = false
    @State private var checkInSuccess = false

    var body: some View {
        VStack(spacing: 20) {
            Text("🎟️ Your Ticket")
                .font(.title)
                .bold()

            Text(purchase.eventTitle)
                .font(.headline)

            Text("Type: \(purchase.type.capitalized)")
            Text("Quantity: \(purchase.quantity)")
            Text("Amount Paid: $\(String(format: "%.2f", purchase.totalAmount))")

            Text("Purchase ID")
                .font(.caption)
                .foregroundColor(.gray)

            Text(purchase.id)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.blue)

            if checkInSuccess {
                Label("✅ Checked In", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.headline)
            } else {
                Button(action: handleCheckIn) {
                    Text("Check In")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(isCheckedIn)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            loadCheckInStatus()
        }
    }

    private func loadCheckInStatus() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(userId).child(purchase.id)

        ref.observeSingleEvent(of: .value) { snapshot in
            if let data = snapshot.value as? [String: Any],
               let checked = data["checkedIn"] as? Bool {
                self.isCheckedIn = checked
                self.checkInSuccess = checked
            }
        }
    }

    private func handleCheckIn() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases").child(userId).child(purchase.id)

        ref.updateChildValues(["checkedIn": true]) { error, _ in
            if error == nil {
                self.checkInSuccess = true
                self.isCheckedIn = true
            }
        }
    }
}

// MARK: - EventStatsView.swift

import SwiftUI
import Firebase

struct EventStatsView: View {
    let event: EventModel
    @State private var checkIns: [PurchaseModel] = []
    @State private var totalTickets = 0
    @State private var totalTables = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Event Stats")
                    .font(.largeTitle)
                    .bold()

                Text("Title: \(event.title)")
                    .font(.headline)

                Text("Total Tickets Sold: \(totalTickets)")
                Text("Total Tables Booked: \(totalTables)")
                Text("Checked-In Attendees: \(checkIns.count)")

                Divider()

                Text("Checked-In Users")
                    .font(.title3)
                    .bold()

                if checkIns.isEmpty {
                    Text("No one has checked in yet.")
                        .foregroundColor(.gray)
                        .padding(.top, 4)
                } else {
                    ForEach(checkIns) { purchase in
                        HStack(alignment: .top, spacing: 12) {
                            UserAvatarView(userId: purchase.userId)

                            VStack(alignment: .leading, spacing: 2) {
                                UserNameView(userId: purchase.userId)

                                Text("Type: \(purchase.type.capitalized) | Qty: \(purchase.quantity)")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }
                        Divider()
                    }
                }
            }
            .padding()
            .onAppear {
                loadStats()
            }
        }
    }

    private func loadStats() {
        let ref = Database.database().reference().child("purchases")

        ref.observeSingleEvent(of: .value) { snapshot in
            var checked: [PurchaseModel] = []
            var ticketTotal = 0
            var tableTotal = 0

            for case let userSnapshot as DataSnapshot in snapshot.children {
                for case let purchaseSnapshot as DataSnapshot in userSnapshot.children {
                    guard let value = purchaseSnapshot.value as? [String: Any],
                          value["eventId"] as? String == event.id else { continue }

                    let type = value["type"] as? String ?? "ticket"
                    let quantity = value["quantity"] as? Int ?? 0

                    if type == "ticket" {
                        ticketTotal += quantity
                    } else if type == "table" {
                        tableTotal += quantity
                    }

                    if value["checkedIn"] as? Bool == true {
                        let model = PurchaseModel(
                            id: purchaseSnapshot.key,
                            userId: value["userId"] as? String ?? "",
                            eventId: event.id,
                            eventTitle: value["eventTitle"] as? String ?? "",
                            eventImagePath: value["eventImagePath"] as? String ?? "",
                            quantity: quantity,
                            type: type,
                            totalAmount: value["totalAmount"] as? Double ?? 0.0,
                            timestamp: value["timestamp"] as? TimeInterval ?? 0.0
                        )
                        checked.append(model)
                    }
                }
            }

            self.totalTickets = ticketTotal
            self.totalTables = tableTotal
            self.checkIns = checked
        }
    }
}

// MARK: - UserNameView

struct UserNameView: View {
    let userId: String
    @State private var name: String = ""

    var body: some View {
        Text(name.isEmpty ? "User: \(userId.prefix(8))..." : "User: \(name)")
            .font(.subheadline)
            .foregroundColor(.primary)
            .onAppear { fetchName() }
    }

    private func fetchName() {
        let ref = Database.database().reference().child("users").child(userId).child("name")
        ref.observeSingleEvent(of: .value) { snapshot in
            if let value = snapshot.value as? String {
                self.name = value
            }
        }
    }
}

// MARK: - UserAvatarView

struct UserAvatarView: View {
    let userId: String
    @State private var imageURL: String? = nil
    @State private var initials: String = "?"

    var body: some View {
        Group {
            if let url = imageURL, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    if let img = phase.image {
                        img.resizable()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .onAppear {
            loadProfileImage()
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .overlay(
                Text(initials)
                    .foregroundColor(.black)
                    .font(.caption)
            )
    }

    private func loadProfileImage() {
        let ref = Database.database().reference().child("users").child(userId)

        ref.observeSingleEvent(of: .value) { snapshot in
            if let dict = snapshot.value as? [String: Any] {
                self.imageURL = dict["profileImageURL"] as? String
                if let name = dict["name"] as? String {
                    self.initials = name.split(separator: " ").compactMap { $0.first }.prefix(2).map { String($0) }.joined().uppercased()
                }
            }
        }
    }
}



// MARK: - EventTabView
struct EventTabView: View {
    @State private var selectedTab = 0
    @State private var showCreate = false

    var body: some View {
        VStack {
            Picker("View", selection: $selectedTab) {
                Text("All Events").tag(0)
                Text("My Events").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()

            if selectedTab == 0 {
                EventFeedView()
            } else {
                MyEventsView()
            }

            Button(action: {
                showCreate = true
            }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Create Event")
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .sheet(isPresented: $showCreate) {
                CreateEventView()
            }
            .padding()
        }
    }
}


import SwiftUI
import FirebaseStorage

struct EventImageView: View {
    let imagePath: String
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var fetchAttempted = false

    var body: some View {
        ZStack {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if isLoading {
                ProgressView("Loading...")
            } else {
                Rectangle()
                    .foregroundColor(.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.white)
                            .font(.title)
                    )
            }
        }
        .frame(height: 200)
        .clipped()
        .cornerRadius(10)
        .onAppear {
            if !fetchAttempted {
                fetchAttempted = true
                fetchImage()
            }
        }
    }

    private func fetchImage() {
        print("🔍 Fetching image URL for path: \(imagePath)")
        let storageRef = Storage.storage().reference(withPath: imagePath)
        storageRef.downloadURL { url, error in
            if let url = url {
                print("✅ Download URL obtained: \(url.absoluteString)")
                loadImageData(from: url)
            } else {
                print("❌ Failed to fetch image URL: \(error?.localizedDescription ?? "Unknown error")")
                isLoading = false
            }
        }
    }

    private func loadImageData(from url: URL, retries: Int = 3) {
        print("📥 Attempting to load image from: \(url.absoluteString), retries left: \(retries)")
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let data = data, error == nil {
                DispatchQueue.main.async {
                    print("✅ Retried image data loaded successfully")
                    imageData = data
                    isLoading = false
                }
            } else if retries > 0 {
                print("🔁 Retrying image download (\(retries - 1) left)...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    loadImageData(from: url, retries: retries - 1)
                }
            } else {
                print("❌ Final image fetch failed after retries: \(error?.localizedDescription ?? "Unknown error")")
                DispatchQueue.main.async {
                    isLoading = false
                }
            }
        }.resume()
    }
}


// MARK: - CreateEventView
import SwiftUI
import Firebase
import FirebaseStorage

struct CreateEventView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var title = ""
    @State private var description = ""
    @State private var selectedDate = Date()
    @State private var payoutMethod = "PayPal"
    @State private var payoutDetails = ""
    @State private var ticketPrice: Double = 0.0
    @State private var ticketQuantity: Int = 0
    @State private var tablePrice: Double = 0.0
    @State private var tableQuantity: Int = 0
    @State private var selectedImage: UIImage?
    @State private var isUploading = false
    @State private var showImagePicker = false
    @State private var location = ""

    let payoutOptions = ["PayPal", "CashApp"]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Event Details")) {
                    TextField("Event Title", text: $title)
                    TextField("Event Location", text: $location)
                    TextField("Event Description", text: $description)
                    DatePicker("Event Date & Time", selection: $selectedDate)
                }
                
                Section(header: Text("Event Image")) {
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                    }
                    Button("Select Event Image") {
                        showImagePicker = true
                    }
                }
                
                Section(header: Text("Payout Information")) {
                    Picker("Payout Method", selection: $payoutMethod) {
                        ForEach(payoutOptions, id: \.self) { method in
                            Text(method)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    TextField(payoutMethod == "PayPal" ? "Enter PayPal Email" : "Enter Cash App Tag", text: $payoutDetails)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }


                Section(header: Text("Ticket Sales")) {
                    Text("Ticket Price (USD)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField("", value: $ticketPrice, format: .number)
                        .keyboardType(.decimalPad)

                    Text("Number of Tickets")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField("", value: $ticketQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("Table Booking")) {
                    Text("Table Price (USD)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField("", value: $tablePrice, format: .number)
                        .keyboardType(.decimalPad)

                    Text("Number of Tables")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField("", value: $tableQuantity, format: .number)
                        .keyboardType(.numberPad)
                }


                                    if isUploading {
                                        ProgressView("Uploading...")
                                            .progressViewStyle(CircularProgressViewStyle())
                                    } else {
                                        Button("Create Event") {
                                            createEvent()
                                        }
                                    }
                                }
                                .navigationTitle("New Event")
                                .sheet(isPresented: $showImagePicker) {
                                    ImagePicker(selectedImage: $selectedImage)
                                }
                            }
                        }
                
                func createEvent() {
                    guard let userId = Auth.auth().currentUser?.uid else { return }
                    guard !title.isEmpty, !description.isEmpty, selectedImage != nil else { return }
                    isUploading = true
                    
                    if let image = selectedImage {
                        uploadEventImage(image) { imagePath in
                            guard let imagePath = imagePath else {
                                isUploading = false
                                return
                            }
                            saveEventData(imagePath: imagePath, userId: userId)
                        }
                    }
                }
                
                func uploadEventImage(_ image: UIImage, completion: @escaping (String?) -> Void) {
                    guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                        print("❌ Failed to convert image to data")
                        completion(nil)
                        return
                    }
                    
                    let imageID = UUID().uuidString
                    let storageRef = Storage.storage().reference().child("eventImages/\(imageID).jpg")
                    let metadata = StorageMetadata()
                    metadata.contentType = "image/jpeg"
                    
                    storageRef.putData(imageData, metadata: metadata) { metadata, error in
                        if let error = error {
                            print("❌ Image upload failed: \(error.localizedDescription)")
                            completion(nil)
                        } else {
                            print("✅ Image uploaded successfully: \(imageID).jpg")
                            completion("eventImages/\(imageID).jpg")
                        }
                    }
                }
                
                func saveEventData(imagePath: String, userId: String) {
                    let ref = Database.database().reference().child("events").childByAutoId()
                    let eventId = ref.key ?? UUID().uuidString
                    let data: [String: Any] = [
                        "id": eventId,
                        "title": title,
                        "description": description,
                        "date": selectedDate.timeIntervalSince1970,
                        "timestamp": Date().timeIntervalSince1970,
                        "payoutMethod": payoutMethod,
                        "payoutDetails": payoutDetails,
                        "location": location,
                        "ticketPrice": ticketPrice,
                        "ticketQuantity": ticketQuantity,
                        "tablePrice": tablePrice,
                        "tableQuantity": tableQuantity,
                        "imagePath": imagePath,
                        "userId": userId
                    ]
                    
                    ref.setValue(data) { error, _ in
                        isUploading = false
                        if error == nil {
                            presentationMode.wrappedValue.dismiss()
                        } else {
                            print("❌ Failed to save event: \(error!.localizedDescription)")
                        }
                    }
                }
            }
// MARK: - EditEventView
import SwiftUI
import Firebase
import FirebaseStorage

struct EditEventView: View {
    @Environment(\.presentationMode) var presentationMode
    let event: EventModel

    @State private var title: String
    @State private var description: String
    @State private var selectedDate: Date
    @State private var payoutMethod: String
    @State private var payoutDetails: String
    @State private var ticketPrice: Double
    @State private var ticketQuantity: Int
    @State private var tablePrice: Double
    @State private var tableQuantity: Int
    @State private var location: String
    @State private var selectedImage: UIImage?
    @State private var showImagePicker = false
    @State private var isUploading = false

    let payoutOptions = ["PayPal", "CashApp"]

    init(event: EventModel) {
        self.event = event
        _title = State(initialValue: event.title)
        _description = State(initialValue: event.description)
        _location = State(initialValue: event.location)
        _selectedDate = State(initialValue: event.date)
        _payoutMethod = State(initialValue: event.payoutMethod)
        _payoutDetails = State(initialValue: event.payoutDetails)
        _ticketPrice = State(initialValue: event.ticketPrice)
        _ticketQuantity = State(initialValue: event.ticketQuantity)
        _tablePrice = State(initialValue: event.tablePrice)
        _tableQuantity = State(initialValue: event.tableQuantity)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Event Details")) {
                    TextField("Event Title", text: $title)
                    TextField("Event Description", text: $description)
                    TextField("Event Location", text: $location)
                    DatePicker("Event Date & Time", selection: $selectedDate)
                }

                Section(header: Text("Update Image")) {
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                    }
                    Button("Select New Image") {
                        showImagePicker = true
                    }
                }

                Section(header: Text("Payout Information")) {
                    Picker("Payout Method", selection: $payoutMethod) {
                        ForEach(payoutOptions, id: \.self) { method in
                            Text(method)
                        }
                    }
                    TextField(payoutMethod == "PayPal" ? "Enter PayPal Email" : "Enter Cash App Tag", text: $payoutDetails)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }

                Section(header: Text("Ticket Sales")) {
                    TextField("Ticket Price (USD)", value: $ticketPrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Number of Tickets", value: $ticketQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("Table Booking")) {
                    TextField("Table Price (USD)", value: $tablePrice, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Number of Tables", value: $tableQuantity, format: .number)
                        .keyboardType(.numberPad)
                }

                if isUploading {
                    ProgressView("Updating...")
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Button("Save Changes") {
                        updateEvent()
                    }
                }
            }
            .navigationTitle("Edit Event")
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $selectedImage)
            }
        }
    }

    func updateEvent() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        isUploading = true

        if let newImage = selectedImage {
            uploadNewImage(newImage) { imagePath in
                guard let path = imagePath else {
                    isUploading = false
                    return
                }
                saveChanges(imagePath: path, userId: userId)
            }
        } else {
            saveChanges(imagePath: event.imagePath, userId: userId)
        }
    }

    func uploadNewImage(_ image: UIImage, completion: @escaping (String?) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            completion(nil)
            return
        }

        let imageID = UUID().uuidString
        let storageRef = Storage.storage().reference().child("eventImages/\(imageID).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        storageRef.putData(imageData, metadata: metadata) { _, error in
            if let error = error {
                print("❌ Image upload error: \(error.localizedDescription)")
                completion(nil)
            } else {
                completion("eventImages/\(imageID).jpg")
            }
        }
    }

    func saveChanges(imagePath: String, userId: String) {
        let ref = Database.database().reference().child("events/\(event.id)")
        let data: [String: Any] = [
            "title": title,
            "description": description,
            "location": location,
            "date": selectedDate.timeIntervalSince1970,
            "timestamp": Date().timeIntervalSince1970,
            "payoutMethod": payoutMethod,
            "payoutDetails": payoutDetails,
            "ticketPrice": ticketPrice,
            "ticketQuantity": ticketQuantity,
            "tablePrice": tablePrice,
            "tableQuantity": tableQuantity,
            "imagePath": imagePath,
            "userId": userId
        ]

        ref.updateChildValues(data) { error, _ in
            isUploading = false
            if error == nil {
                presentationMode.wrappedValue.dismiss()
            } else {
                print("❌ Failed to update event: \(error!.localizedDescription)")
            }
        }
    }
}



// MARK: - RSSCardView
struct RSSCardView: View {
    let article: RSSArticle
    @Binding var selectedURL: URL?
    @Binding var showWebView: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL = article.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(12)

                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .cornerRadius(12)

                    case .failure:
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 200)

                    @unknown default:
                        EmptyView()
                    }
                }
            }

            Text(article.title)
                .font(.headline)
                .foregroundColor(.white)

            Text(article.description)
                .font(.subheadline)
                .foregroundColor(.gray)
                .lineLimit(2)

            Button(action: {
                if let url = URL(string: article.link) {
                    selectedURL = url
                    showWebView = true
                }
            }) {
                Text("Read More")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(16)
        .shadow(radius: 3)
    }
}

import SwiftUI
import Firebase
import FirebaseAuth

struct EventDetailView: View {
    let event: EventModel
    @State private var showWebViewModal = false
    @State private var selectedURL: URL?
    @State private var showCheckoutConfirmation = false
    @State private var isSaved = false
    @State private var showShareSheet = false
    @State private var showCopiedAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    EventImageView(imagePath: event.imagePath)
                        .frame(height: 250)
                        .cornerRadius(12)

                    Text(formattedDate(event.date))
                        .font(.caption)
                        .bold()
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                        .padding()
                }

                Text(event.title)
                    .font(.title)
                    .bold()
                    .padding(.top)

                Text(event.description)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)

                if event.ticketPrice > 0 || event.tablePrice > 0 {
                    Button(action: {
                        showCheckoutConfirmation = true
                    }) {
                        HStack {
                            Image(systemName: "cart.fill")
                            Text("Buy Tickets / Tables")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }

                HStack {
                    Button(action: {
                        showShareSheet = true
                    }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .padding(8)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                    }

                    Button(action: toggleSaveEvent) {
                        Label(isSaved ? "Saved" : "Remind Me", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                            .padding(8)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                    }
                }
            }
            .padding()
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .preferredColorScheme(.dark)
        .onAppear {
            checkIfSaved()
        }
        .sheet(isPresented: $showWebViewModal) {
            if let url = selectedURL {
                NavigationView {
                    WebView(url: url)
                        .navigationBarTitle("Secure Checkout", displayMode: .inline)
                        .navigationBarItems(trailing: Button("Close") {
                            showWebViewModal = false
                        })
                }
            }
        }
        .sheet(isPresented: $showCheckoutConfirmation) {
            CheckoutConfirmationView(event: event) { ticketQty, tableQty in
                let baseTotal = Double(ticketQty) * event.ticketPrice + Double(tableQty) * event.tablePrice
                let totalWithFee = baseTotal * 1.02

                let urlString = """
                https://blackappios.web.app/index.html?\
                eventId=\(event.id)&\
                eventName=\(event.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&\
                eventTime=\(Int(event.date.timeIntervalSince1970))&\
                userId=\(Auth.auth().currentUser?.uid ?? "anonymous")&\
                ticketQty=\(ticketQty)&\
                ticketPrice=\(event.ticketPrice)&\
                tableQty=\(tableQty)&\
                tablePrice=\(event.tablePrice)&\
                baseTotal=\(String(format: "%.2f", baseTotal))&\
                totalWithFee=\(String(format: "%.2f", totalWithFee))&\
                payoutMethod=\(event.payoutMethod)&\
                payoutDetails=\(event.payoutDetails.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&\
                eventImagePath=\(event.imagePath)
                """

                if let url = URL(string: urlString) {
                    selectedURL = url
                    showWebViewModal = true
                } else {
                    print("❌ Failed to create checkout URL")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareModalView(eventId: event.id, eventTitle: event.title, showCopiedAlert: $showCopiedAlert)
        }
        .overlay(
            VStack {
                if showCopiedAlert {
                    Text("Link copied to clipboard!")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                        .padding(.top, 40)
                }
                Spacer()
            }
        )
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func toggleSaveEvent() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedEvents").child(userId).child(event.id)

        if isSaved {
            ref.removeValue()
            isSaved = false
        } else {
            let values: [String: Any] = [
                "eventId": event.id,
                "title": event.title,
                "timestamp": Date().timeIntervalSince1970
            ]
            ref.setValue(values)
            isSaved = true
        }
    }

    private func checkIfSaved() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedEvents").child(userId).child(event.id)

        ref.observeSingleEvent(of: .value) { snapshot in
            self.isSaved = snapshot.exists()
        }
    }
}

struct ShareModalView: View {
    let eventId: String
    let eventTitle: String
    @Binding var showCopiedAlert: Bool

    var hostedURL: String {
        return "https://blackappios.web.app/event.html?eventId=\(eventId)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Share this Event")
                .font(.headline)
                .padding(.top)

            HStack(spacing: 20) {
                ShareIconButton(systemImage: "f.square") {
                    shareTo(url: "https://www.facebook.com/sharer/sharer.php?u=\(hostedURL)")
                }
                ShareIconButton(systemImage: "camera") {
                    shareTo(url: "https://www.instagram.com/?url=\(hostedURL)")
                }
                ShareIconButton(systemImage: "message.fill") {
                    shareTo(url: "https://api.whatsapp.com/send?text=\(eventTitle) \(hostedURL)")
                }
                ShareIconButton(systemImage: "bird") {
                    shareTo(url: "https://twitter.com/intent/tweet?text=\(eventTitle)&url=\(hostedURL)")
                }
            }

            Button(action: {
                UIPasteboard.general.string = hostedURL
                showCopiedAlert = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    showCopiedAlert = false
                }
            }) {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("Copy Link")
                }
                .foregroundColor(.blue)
                .padding()
                .background(Color.white)
                .cornerRadius(10)
            }

            Spacer()
        }
        .padding()
        .background(Color.black)
        .presentationDetents([.medium])
    }

    private func shareTo(url: String) {
        if let shareURL = URL(string: url) {
            UIApplication.shared.open(shareURL)
        }
    }
}

struct ShareIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .padding(10)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
