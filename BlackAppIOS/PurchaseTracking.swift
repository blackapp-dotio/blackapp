// MARK: - PurchaseTicketView
import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage
import Foundation
import FirebaseDatabase

// nimport SharedTypes // if it’s inside a module

struct PurchaseTicketView: View {
    let purchase: PurchaseModel
    @Environment(\.presentationMode) var presentationMode
    @State private var imageData: Data?

    var body: some View {
        VStack(spacing: 20) {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 200)
                    .cornerRadius(12)
            } else {
                ProgressView("Loading Ticket...")
            }

            Text("Event: \(purchase.eventTitle)")
                .font(.headline)
            Text("Type: \(purchase.type.capitalized)")
            Text("Quantity: \(purchase.quantity)")
            Text("Total Paid: $\(String(format: "%.2f", purchase.totalAmount))")
            Text("Confirmation #: \(purchase.id.prefix(8).uppercased())")

            Button("Close") {
                presentationMode.wrappedValue.dismiss()
            }
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(10)
        }
        .padding()
        .onAppear {
            loadImage()
        }
    }

    func loadImage() {
        let ref = Storage.storage().reference(withPath: purchase.eventImagePath)
        ref.downloadURL { url, error in
            if let url = url {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    DispatchQueue.main.async {
                        self.imageData = data
                    }
                }.resume()
            }
        }
    }
}

// MARK: - Log Purchase Function
func logPurchase(eventId: String, eventTitle: String, eventImagePath: String, quantity: Int, type: String, totalAmount: Double) {
    guard let buyerId = Auth.auth().currentUser?.uid else { return }
    let ref = Database.database().reference().child("purchases").childByAutoId()
    let purchaseData: [String: Any] = [
        "userId": buyerId,
        "eventId": eventId,
        "eventTitle": eventTitle,
        "eventImagePath": eventImagePath,
        "quantity": quantity,
        "type": type,
        "totalAmount": totalAmount,
        "timestamp": Date().timeIntervalSince1970
    ]
    ref.setValue(purchaseData)
    print("✅ Purchase logged for \(type): \(quantity) x $\(totalAmount)")
}

// MARK: - MyPurchasedEventsView
struct MyPurchasedEventsView: View {
    @State private var purchases: [PurchaseModel] = []
    @State private var selectedPurchase: PurchaseModel? = nil
    @State private var showProofModal = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(purchases) { purchase in
                        PurchaseRowView(purchase: purchase) {
                            selectedPurchase = purchase
                            showProofModal = true
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("My Tickets")
            .onAppear(perform: fetchMyPurchases)
            .sheet(isPresented: $showProofModal) {
                if let purchase = selectedPurchase {
                    ProofOfPurchaseModal(purchase: purchase)
                }
            }
        }
    }

    func fetchMyPurchases() {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("purchases")
        ref.observeSingleEvent(of: .value) { snapshot in
            var results: [PurchaseModel] = []
            for case let child as DataSnapshot in snapshot.children {
                if let purchase = PurchaseModel.from(snapshot: child), purchase.userId == userId {
                    results.append(purchase)
                }
            }
            self.purchases = results.sorted { $0.timestamp > $1.timestamp }
        }
    }
}

// MARK: - PurchaseRowView
struct PurchaseRowView: View {
    let purchase: PurchaseModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading) {
                Text("Event: \(purchase.eventTitle)").font(.headline)
                Text("Type: \(purchase.type.capitalized) | Quantity: \(purchase.quantity)")
                Text("Total Paid: $\(String(format: "%.2f", purchase.totalAmount))")
                Text("Date: \(formattedDate(purchase.timestamp))")
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        }
    }

    func formattedDate(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - ProofOfPurchaseModal
struct ProofOfPurchaseModal: View {
    let purchase: PurchaseModel

    var body: some View {
        VStack(spacing: 16) {
            Text("🎟️ Proof of Purchase")
                .font(.title2)
                .bold()

            Text("Event: \(purchase.eventTitle)")
            Text("Type: \(purchase.type.capitalized)")
            Text("Quantity: \(purchase.quantity)")
            Text("Total: $\(String(format: "%.2f", purchase.totalAmount))")
            Text("Purchase Date: \(formattedDate(purchase.timestamp))")

            Spacer()
        }
        .padding()
    }

    func formattedDate(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
