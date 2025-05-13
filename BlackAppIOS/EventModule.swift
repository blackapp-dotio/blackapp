// MARK: - EventModel
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

    static func from(snapshot: DataSnapshot) -> EventModel? {
        guard let value = snapshot.value as? [String: Any],
              let title = value["title"] as? String,
              let description = value["description"] as? String,
              let imagePath = value["imagePath"] as? String,
              let timestamp = value["date"] as? TimeInterval,
              let userId = value["userId"] as? String else {
            return nil
        }

        return EventModel(
            id: snapshot.key,
            title: title,
            description: description,
            imagePath: imagePath,
            date: Date(timeIntervalSince1970: timestamp),
            payoutMethod: value["payoutMethod"] as? String ?? "",
            payoutDetails: value["payoutDetails"] as? String ?? "",
            ticketPrice: value["ticketPrice"] as? Double ?? 0.0,
            ticketQuantity: value["ticketQuantity"] as? Int ?? 0,
            tablePrice: value["tablePrice"] as? Double ?? 0.0,
            tableQuantity: value["tableQuantity"] as? Int ?? 0,
            userId: userId
        )
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
    
    let payoutOptions = ["PayPal", "CashApp"]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Event Details")) {
                    TextField("Event Title", text: $title)
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

    @State private var selectedImage: UIImage?
    @State private var showImagePicker = false
    @State private var isUploading = false

    let payoutOptions = ["PayPal", "CashApp"]

    init(event: EventModel) {
        self.event = event
        _title = State(initialValue: event.title)
        _description = State(initialValue: event.description)
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
// MARK: - MyEventsView
import SwiftUI
import Firebase

struct MyEventsView: View {
    @State private var myCreatedEvents: [EventModel] = []
    @State private var myPurchasedEvents: [EventModel] = []
    @State private var selectedURL: URL? = nil
    @State private var showWebView = false

    // For editing modal
    @State private var selectedEventToEdit: EventModel? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Events I've Created")
                        .font(.headline)
                        .padding(.horizontal)

                    ForEach(myCreatedEvents) { event in
                        VStack(alignment: .leading) {
                            EventCardView(event: event, selectedURL: $selectedURL, showWebView: $showWebView)

                            HStack {
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
                            }
                            .padding(.horizontal)
                        }
                    }

                    Divider().padding(.vertical)

                    Text("Events I've Purchased")
                        .font(.headline)
                        .padding(.horizontal)

                    ForEach(myPurchasedEvents) { event in
                        EventCardView(event: event, selectedURL: $selectedURL, showWebView: $showWebView)
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

        ref.observeSingleEvent(of: .value, with: { snapshot in
            var createdEvents: [EventModel] = []

            for child in snapshot.children {
                if let childSnapshot = child as? DataSnapshot,
                   let event = EventModel.from(snapshot: childSnapshot),
                   event.userId == userId {
                    createdEvents.append(event)
                }
            }

            self.myCreatedEvents = createdEvents.sorted { $0.date > $1.date }
        })
    }

    private func fetchMyPurchasedEvents() {
        // Placeholder logic
        self.myPurchasedEvents = []
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
}

import SwiftUI
import FirebaseStorage

// MARK: - EventCardView with Floating Purchase Overlay
struct EventCardView: View {
    let event: EventModel
    @Binding var selectedURL: URL?
    @Binding var showWebView: Bool

    @State private var showOverlay = false
    @State private var purchaseType: String = "ticket"
    @State private var selectedQuantity = 1

    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                EventImageView(imagePath: event.imagePath)
                    .frame(height: 200)
                    .clipped()
                    .cornerRadius(10)

                Text(event.title)
                    .font(.headline)
                    .padding(.top, 5)

                Text(event.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                if event.ticketPrice > 0 && event.ticketQuantity > 0 {
                    Button(action: {
                        purchaseType = "ticket"
                        selectedQuantity = 1
                        showOverlay = true
                    }) {
                        Text("Buy Ticket - $\(String(format: "%.2f", event.ticketPrice * 1.02))")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    .padding(.top, 8)
                }

                if event.tablePrice > 0 && event.tableQuantity > 0 {
                    Button(action: {
                        purchaseType = "table"
                        selectedQuantity = 1
                        showOverlay = true
                    }) {
                        Text("Book Table - $\(String(format: "%.2f", event.tablePrice * 1.02))")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.purple)
                            .cornerRadius(8)
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
            .onTapGesture {
                if let url = URL(string: event.description) {
                    selectedURL = url
                    showWebView = true
                }
            }

            if showOverlay {
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: 16) {
                    Text("Confirm \(purchaseType.capitalized) Purchase")
                        .font(.headline)

                    Stepper("Quantity: \(selectedQuantity)", value: $selectedQuantity, in: 1...(purchaseType == "ticket" ? event.ticketQuantity : event.tableQuantity))
                        .padding(.horizontal)

                    let unitPrice = purchaseType == "ticket" ? event.ticketPrice : event.tablePrice
                    let totalPrice = unitPrice * Double(selectedQuantity) * 1.02

                    Text("Total: $\(String(format: "%.2f", totalPrice))")
                        .font(.title2)
                        .bold()

                    HStack(spacing: 20) {
                        Button("Cancel") {
                            showOverlay = false
                        }
                        .foregroundColor(.red)

                        Button("Confirm & Pay") {
                            openCheckout(for: event, type: purchaseType, quantity: selectedQuantity)
                            showOverlay = false
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.green)
                        .cornerRadius(8)
                    }
                }
                .padding()
                .frame(maxWidth: 300)
                .background(Color.white)
                .cornerRadius(12)
                .shadow(radius: 10)
            }
        }
    }

    private func openCheckout(for event: EventModel, type: String, quantity: Int) {
        let unitPrice = type == "ticket" ? event.ticketPrice : event.tablePrice
        let totalPrice = unitPrice * Double(quantity) * 1.02

        var components = URLComponents(string: "https://checkout.blackapp.com/buy")!
        components.queryItems = [
            URLQueryItem(name: "eventId", value: event.id),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "price", value: String(format: "%.2f", totalPrice)),
            URLQueryItem(name: "quantity", value: "\(quantity)"),
            URLQueryItem(name: "payoutMethod", value: event.payoutMethod),
            URLQueryItem(name: "payoutDetails", value: event.payoutDetails)
        ]

        if let url = components.url {
            selectedURL = url
            showWebView = true
        }
    }
}


            // MARK: - RSSCardView
            struct RSSCardView: View {
                let article: RSSArticle
                @Binding var selectedURL: URL?
                @Binding var showWebView: Bool
                
                var body: some View {
                    VStack(alignment: .leading) {
                        if let imageURL = article.imageURL {
                            AsyncImage(url: imageURL) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView()
                                        .frame(height: 200)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 200)
                                        .clipped()
                                        .cornerRadius(10)
                                case .failure:
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(height: 200)
                                        .cornerRadius(10)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }
                        
                        Text(article.title)
                            .font(.headline)
                            .padding(.top, 5)
                        
                        Text(article.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding()
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(10)
                    .onTapGesture {
                        if let url = URL(string: article.link) {
                            selectedURL = url
                            showWebView = true
                        }
                    }
                }
            }
            
            
            // MARK: - EventDetailView
            struct EventDetailView: View {
                let event: EventModel
                @State private var showWebView = false
                @State private var selectedURL: URL?
                
                var body: some View {
                    ScrollView {
                        VStack(alignment: .leading) {
                            EventImageView(imagePath: event.imagePath)
                                .frame(height: 250)
                                .cornerRadius(12)
                            
                            Text(event.title)
                                .font(.title)
                                .bold()
                                .padding(.top)
                            
                            Text(event.description)
                                .padding(.vertical)
                            
                            Text("Date: \(formattedDate(event.date))")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            
                            Button("Buy Ticket") {
                                selectedURL = URL(string: "https://checkout.blackapp.com/event/\(event.id)")
                                showWebView = true
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .padding()
                    }
                    .sheet(isPresented: $showWebView) {
                        if let url = selectedURL {
                            WebView(url: url).edgesIgnoringSafeArea(.all)
                        }
                    }
                }
                
                func formattedDate(_ date: Date) -> String {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    return formatter.string(from: date)
                }
            }
            
            // MARK: - EventFeedView
            struct EventFeedView: View {
                @State private var platformEvents: [EventModel] = []
                @State private var rssArticles: [RSSArticle] = []
                @State private var selectedURL: URL? = nil
                @State private var showWebView = false
                @State private var isLoading = true
                
                let rssFeedURLs = [
                    "https://rss.app/feeds/nsmT2WdQXSlshmcy.xml",
                    "https://rss.app/feeds/XqrrnyuiP2E5gvZY.xml",
                    "https://rss.app/feeds/uCjXryL38K1J4e29.xml",
                    "https://rss.app/feeds/pv5YufdSsNN6ROH5.xml",
                    "https://rss.app/feeds/keM7mXLp4OlutaGg.xml"
                ]
                
                var body: some View {
                    NavigationView {
                        VStack {
                            if isLoading {
                                ProgressView("Loading Events...")
                                    .padding()
                            } else {
                                List {
                                    Section(header: Text("BlackApp Events")) {
                                        ForEach(platformEvents) { event in
                                            EventCardView(event: event, selectedURL: $selectedURL, showWebView: $showWebView)
                                        }
                                    }
                                    
                                    Section(header: Text("External Events")) {
                                        ForEach(rssArticles) { article in
                                            RSSCardView(article: article, selectedURL: $selectedURL, showWebView: $showWebView)
                                        }
                                    }
                                }
                                .listStyle(.plain)
                            }
                        }
                        .navigationTitle("Events")
                        .background(Color.black)
                        .onAppear {
                            fetchPlatformEvents()
                            fetchFeedsInChunks()
                        }
                        .sheet(isPresented: $showWebView) {
                            if let url = selectedURL {
                                WebView(url: url).edgesIgnoringSafeArea(.all)
                            }
                        }
                    }
                    .preferredColorScheme(.dark)
                }
                
                func fetchPlatformEvents() {
                    let ref = Database.database().reference().child("events")
                    ref.observeSingleEvent(of: .value) { snapshot in
                        var events: [EventModel] = []
                        let now = Date()
                        
                        for case let child as DataSnapshot in snapshot.children {
                            if let event = EventModel.from(snapshot: child), event.date > now {
                                events.append(event)
                            }
                        }
                        
                        self.platformEvents = events.sorted { $0.date > $1.date }
                    }
                }
                
                
                func fetchFeedsInChunks(chunkSize: Int = 2) {
                    Task {
                        let chunks = rssFeedURLs.chunked(into: chunkSize)
                        for chunk in chunks {
                            await withTaskGroup(of: [RSSArticle].self) { group in
                                for url in chunk {
                                    group.addTask { return await fetchFeed(urlString: url) }
                                }
                                for await result in group {
                                    let filtered = result.filter { $0.imageURL != nil }
                                    await MainActor.run {
                                        self.rssArticles.append(contentsOf: filtered)
                                    }
                                }
                            }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        await MainActor.run {
                            isLoading = false
                        }
                    }
                }
                
                func fetchFeed(urlString: String) async -> [RSSArticle] {
                    guard let url = URL(string: urlString) else { return [] }
                    
                    return await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .background).async {
                            let parser = FeedParser(URL: url)
                            let result = parser.parse()
                            
                            var articles: [RSSArticle] = []
                            
                            switch result {
                            case .success(let feed):
                                let items = feed.rssFeed?.items ?? []
                                articles = items.prefix(3).compactMap {
                                    guard let title = $0.title,
                                          let link = $0.link,
                                          let description = $0.description?.strippedHTML(),
                                          let pubDate = $0.pubDate else { return nil }
                                    
                                    let imageURL = extractImageURL(from: $0)
                                    return RSSArticle(title: title, link: link, description: description, pubDate: pubDate, imageURL: imageURL)
                                }
                            case .failure(let error):
                                print("❌ Failed to parse feed: \(error)")
                            }
                            
                            continuation.resume(returning: articles)
                        }
                    }
                }
                
                func extractImageURL(from item: RSSFeedItem) -> URL? {
                    if let mediaURL = item.media?.mediaContents?.first?.attributes?.url {
                        return URL(string: mediaURL)
                    }
                    
                    if let desc = item.description,
                       let imgTagRange = desc.range(of: "<img[^>]+src=\"([^\"]+)\"", options: .regularExpression),
                       let match = desc[imgTagRange].range(of: "src=\"([^\"]+)\"", options: .regularExpression),
                       let urlRange = desc[match].range(of: #"(?<=src=\")[^\"]+"#, options: .regularExpression) {
                        return URL(string: String(desc[match][urlRange]))
                    }
                    
                    return nil
                }
            }
            
