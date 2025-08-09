import SwiftUI
import Firebase
import FirebaseDatabase
import FirebaseAuth

struct BrandBookingsFeedView: View {
    var brand: BrandModel
    @State private var sessions: [BookingSession] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(sessions) { session in
                    BookingCard(session: session)
                        .padding(.horizontal)
                }

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .padding()
                } else if sessions.isEmpty {
                    Text("No sessions available for booking.")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            .padding(.top)
        }
        .background(
            LinearGradient(gradient: Gradient(colors: [.black, .gray.opacity(0.3)]),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        )
        .navigationTitle("\(brand.name) Bookings")
        .onAppear {
            fetchBookingSessions()
        }
    }

    func fetchBookingSessions() {
        print("📅 Fetching bookings for brand ID: \(brand.id)")
        let ref = Database.database().reference().child("brands").child(brand.id).child("bookings")
        ref.observeSingleEvent(of: .value) { snapshot in
            var temp: [BookingSession] = []

            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let session = BookingSession.from(dict: dict, id: child.key) {
                    temp.append(session)
                }
            }

            self.sessions = temp.sorted(by: { $0.timestamp > $1.timestamp })
            self.isLoading = false
            print("✅ Loaded \(temp.count) booking sessions")
        }
    }
}

// MARK: - BookingSession Model

struct BookingSession: Identifiable {
    var id: String
    var title: String
    var description: String
    var price: Double
    var durationMinutes: Int
    var timestamp: TimeInterval

    static func from(dict: [String: Any], id: String) -> BookingSession? {
        guard let title = dict["title"] as? String,
              let description = dict["description"] as? String,
              let price = dict["price"] as? Double,
              let duration = dict["durationMinutes"] as? Int,
              let timestamp = dict["timestamp"] as? TimeInterval else {
            return nil
        }

        return BookingSession(id: id, title: title, description: description, price: price, durationMinutes: duration, timestamp: timestamp)
    }

    var formattedDuration: String {
        "\(durationMinutes) min"
    }
}

// MARK: - Booking Card View

struct BookingCard: View {
    let session: BookingSession
    @State private var isSaved = false
    @State private var showShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(session.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()

                Button(action: toggleSave) {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .foregroundColor(isSaved ? .red : .white)
                }

                Button(action: { showShareSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.white)
                }
            }

            Text(session.description)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(4)

            HStack {
                Text("Duration: \(session.formattedDuration)")
                    .font(.footnote)
                    .foregroundColor(.gray)

                Spacer()

                Text(String(format: "$%.2f", session.price))
                    .font(.headline)
                    .foregroundColor(.green)
            }

            HStack {
                Spacer()
                Button(action: {
                    // TODO: Hook into booking flow
                }) {
                    Text("Book Now")
                        .foregroundColor(.black)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 6)
        .onAppear {
            checkSavedStatus()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [shareMessage()])
        }
    }

    func toggleSave() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedBookings").child(uid).child(session.id)

        if isSaved {
            ref.removeValue()
            isSaved = false
        } else {
            ref.setValue(true)
            isSaved = true
        }
    }

    func checkSavedStatus() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("savedBookings").child(uid).child(session.id)

        ref.observeSingleEvent(of: .value) { snapshot in
            isSaved = snapshot.exists()
        }
    }

    func shareMessage() -> String {
        return "📅 Check out this session: \(session.title) — \(session.formattedDuration) for $\(session.price)\nNow available for booking on BlackApp!"
    }
}

// MARK: - Share Sheet
import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        return UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
