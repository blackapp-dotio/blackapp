import SwiftUI
import FirebaseAuth
import FirebaseDatabase

struct MyTicketsView: View {
    @State private var purchases: [Purchase] = []
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading your tickets...")
                        .padding()
                } else if purchases.isEmpty {
                    Text("You haven’t purchased any tickets or tables yet.")
                        .foregroundColor(.gray)
                        .padding()
                } else {
                    List {
                        ForEach(purchases.sorted(by: { $0.timestamp > $1.timestamp })) { purchase in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(purchase.type.capitalized) for \(purchase.eventName)")
                                    .font(.headline)
                                    .foregroundColor(.white)

                                Text("Qty: \(purchase.quantity)")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)

                                Text("Total Paid: $\(purchase.amount)")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)

                                Text("Date: \(purchase.formattedDate)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(Color.black)
                        }
                    }
                    .listStyle(.plain)
                    .background(Color.black)
                }
            }
            .navigationTitle("My Tickets")
            .onAppear {
                fetchUserPurchases()
            }
        }
        .preferredColorScheme(.dark)
    }

    func fetchUserPurchases() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        let ref = Database.database().reference().child("purchases").child(userId)

        ref.observeSingleEvent(of: .value) { snapshot in
            var loaded: [Purchase] = []

            for child in snapshot.children {
                if let snap = child as? DataSnapshot,
                   let dict = snap.value as? [String: Any],
                   let eventId = dict["eventId"] as? String,
                   let eventName = dict["eventName"] as? String,
                   let type = dict["type"] as? String,
                   let quantity = dict["quantity"] as? Int,
                   let amount = dict["amount"] as? String,
                   let timestamp = dict["timestamp"] as? TimeInterval {

                    let purchase = Purchase(
                        id: snap.key,
                        eventId: eventId,
                        eventName: eventName,
                        type: type,
                        quantity: quantity,
                        amount: amount,
                        timestamp: timestamp
                    )
                    loaded.append(purchase)
                }
            }

            DispatchQueue.main.async {
                self.purchases = loaded
                self.isLoading = false
            }
        }
    }
}

struct Purchase: Identifiable {
    let id: String
    let eventId: String
    let eventName: String
    let type: String  // "ticket" or "table"
    let quantity: Int
    let amount: String
    let timestamp: TimeInterval

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
