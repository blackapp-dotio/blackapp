import SwiftUI
import Firebase
import FirebaseDatabase

struct BrandBookingsConfigView: View {
    var brand: BrandModel

    // Form state
    @State private var title = ""
    @State private var description = ""
    @State private var price = ""
    @State private var sessionDate = Date()
    @State private var durationMinutes = ""
    @State private var isUploading = false
    @State private var uploadMessage = ""

    // Edit/list state
    @State private var sessions: [BrandBookingSession] = []
    @State private var isLoadingList = true
    @State private var editingSessionId: String? = nil

    private var isEditing: Bool { editingSessionId != nil }
    private var isFormValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty,
              !price.isEmpty, !durationMinutes.isEmpty,
              Double(price) != nil, Int(durationMinutes) != nil else { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // Header
                VStack(spacing: 6) {
                    Text(isEditing ? "Edit Booking Session" : "Create Booking Session")
                        .font(.title2).bold()
                        .foregroundColor(.white)
                    if let id = editingSessionId {
                        Text("Editing: \(id)")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                // Form
                Group {
                    TextField("Session Title", text: $title)
                    TextField("Description", text: $description)
                    TextField("Price (USD)", text: $price)
                        .keyboardType(.decimalPad)
                    TextField("Duration (Minutes)", text: $durationMinutes)
                        .keyboardType(.numberPad)
                }
                .textFieldStyle(RoundedBorderTextFieldStyle())

                DatePicker("Session Date & Time", selection: $sessionDate)
                    .foregroundColor(.white)

                if isUploading {
                    ProgressView(isEditing ? "Saving changes..." : "Uploading...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }

                HStack(spacing: 12) {
                    Button(isEditing ? "Save Changes" : "Save Session") {
                        saveOrUpdateBooking()
                    }
                    .disabled(isUploading || !isFormValid)
                    .padding()
                    .background(isEditing ? Color.orange : Color.teal)
                    .foregroundColor(.white)
                    .cornerRadius(10)

                    if isEditing {
                        Button("Cancel") {
                            clearForm()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }

                if !uploadMessage.isEmpty {
                    Text(uploadMessage)
                        .foregroundColor(.white)
                        .padding(.top, 4)
                }

                Divider().background(Color.white.opacity(0.2)).padding(.vertical, 8)

                // Existing sessions
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Existing Sessions", systemImage: "calendar")
                            .foregroundColor(.white)
                            .font(.headline)
                        Spacer()
                        Button {
                            fetchSessions()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.white)
                        }
                    }

                    if isLoadingList {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else if sessions.isEmpty {
                        Text("No sessions yet.")
                            .foregroundColor(.white.opacity(0.6))
                    } else {
                        ForEach(sessions, id: \.id) { s in
                            BrandBookingRow(
                                session: s,
                                onEdit: { loadForEdit(s) },
                                onDelete: { deleteSession(s) }
                            )
                        }
                    }
                }
                .glassCard()
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { fetchSessions() }
        .navigationTitle("Bookings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Save / Update
    private func saveOrUpdateBooking() {
        guard let priceVal = Double(price),
              let duration = Int(durationMinutes) else {
            uploadMessage = "Fill in all fields correctly."
            return
        }

        isUploading = true
        uploadMessage = ""

        let ref = Database.database().reference()
        let bookingId = editingSessionId ?? UUID().uuidString

        let bookingData: [String: Any] = [
            "id": bookingId,
            "title": title,
            "description": description,
            "price": priceVal,
            "durationMinutes": duration,
            "datetime": sessionDate.timeIntervalSince1970,
            "timestamp": Date().timeIntervalSince1970
        ]

        print("📝 \(isEditing ? "Updating" : "Saving") session \(bookingId) for brand \(brand.id)")
        ref.child("brands/\(brand.id)/bookings").child(bookingId).setValue(bookingData) { error, _ in
            if let error = error {
                uploadMessage = "❌ Failed to save session: \(error.localizedDescription)"
                print(uploadMessage)
            } else {
                ref.child("brands/\(brand.id)/toolsEnabled/bookings").setValue(true)
                uploadMessage = isEditing ? "✅ Changes saved!" : "✅ Session saved!"
                print(uploadMessage)
                fetchSessions()
                clearForm()
            }
            isUploading = false
        }
    }

    // MARK: - Fetch list
    private func fetchSessions() {
        isLoadingList = true
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("bookings")

        print("📥 Fetching sessions for brand \(brand.id)")
        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [BrandBookingSession] = []
            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let s = BrandBookingSession.from(dict: dict, id: child.key) {
                    temp.append(s)
                } else {
                    print("⚠️ Skipped malformed session \(child.key)")
                }
            }
            self.sessions = temp.sorted(by: { $0.datetime > $1.datetime })
            self.isLoadingList = false
            print("✅ Loaded \(self.sessions.count) sessions")
        }
    }

    // MARK: - Edit
    private func loadForEdit(_ s: BrandBookingSession) {
        editingSessionId = s.id
        title = s.title
        description = s.description
        price = String(format: "%.2f", s.price)
        durationMinutes = "\(s.durationMinutes)"
        sessionDate = Date(timeIntervalSince1970: s.datetime)
        uploadMessage = ""
        print("✏️ Loaded session \(s.id) for editing")
    }

    // MARK: - Delete
    private func deleteSession(_ s: BrandBookingSession) {
        let ref = Database.database().reference()
            .child("brands")
            .child(brand.id)
            .child("bookings")
            .child(s.id)

        print("🗑️ Deleting session \(s.id)")
        ref.removeValue { error, _ in
            if let error = error {
                print("❌ Failed to delete: \(error.localizedDescription)")
                uploadMessage = "❌ Failed to delete: \(error.localizedDescription)"
            } else {
                sessions.removeAll { $0.id == s.id }
                if editingSessionId == s.id { clearForm() }
                print("✅ Deleted session \(s.id)")
            }
        }
    }

    // MARK: - Reset
    private func clearForm() {
        title = ""
        description = ""
        price = ""
        durationMinutes = ""
        sessionDate = Date()
        editingSessionId = nil
    }
}

// MARK: - Model (unique name to avoid collisions)
struct BrandBookingSession: Identifiable {
    let id: String
    let title: String
    let description: String
    let price: Double
    let durationMinutes: Int
    let datetime: TimeInterval
    let timestamp: TimeInterval

    static func from(dict: [String: Any], id: String) -> BrandBookingSession? {
        guard let title = dict["title"] as? String,
              let description = dict["description"] as? String,
              let price = dict["price"] as? Double,
              let duration = dict["durationMinutes"] as? Int,
              let datetime = dict["datetime"] as? TimeInterval,
              let ts = dict["timestamp"] as? TimeInterval else {
            return nil
        }
        return BrandBookingSession(
            id: id,
            title: title,
            description: description,
            price: price,
            durationMinutes: duration,
            datetime: datetime,
            timestamp: ts
        )
    }
}

// MARK: - Row
private struct BrandBookingRow: View {
    let session: BrandBookingSession
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(session.description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Text("$\(session.price, specifier: "%.2f")")
                        .foregroundColor(.green)
                    Text("\(session.durationMinutes) min")
                        .foregroundColor(.white.opacity(0.7))
                    Text(Self.formatDate(session.datetime))
                        .foregroundColor(.white.opacity(0.6))
                }
                .font(.footnote)
            }
            Spacer()
            VStack(spacing: 8) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .foregroundColor(.yellow)
                }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    static func formatDate(_ ts: TimeInterval) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - Local “glass” helper (unique name to avoid clashes)
private extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        self
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
