import SwiftUI
import Firebase
import FirebaseAuth
import FirebaseDatabase

struct CheckoutConfirmationView: View {
    let event: EventModel
    var onConfirm: ((Int, Int) -> Void)? = nil
    @Environment(\.presentationMode) var presentationMode

    // Quantities
    @State private var ticketQty = 0
    @State private var tableQty = 0

    // ✅ Single source of truth for buyer platform fee
    private let platformBuyerFeeRate: Double = 0.05

    // Subtotals
    var ticketTotal: Double { Double(ticketQty) * event.ticketPrice }
    var tableTotal: Double { Double(tableQty) * event.tablePrice }
    var subTotal: Double { ticketTotal + tableTotal }

    // Fee + total (rounded to 2 decimals)
    var platformFee: Double {
        round2(subTotal * platformBuyerFeeRate)
    }
    var totalWithFee: Double {
        round2(subTotal + platformFee)
    }

    var body: some View {
        NavigationView {
            Form {
                // Quantities
                Section(header: Text("Select Quantities")) {
                    if event.ticketQuantity > 0 {
                        Stepper("Tickets (\(ticketQty))", value: $ticketQty, in: 0...event.ticketQuantity)
                        Text("Subtotal: $\(ticketTotal, specifier: "%.2f")").font(.caption)
                    }

                    if event.tableQuantity > 0 {
                        Stepper("Tables (\(tableQty))", value: $tableQty, in: 0...event.tableQuantity)
                        Text("Subtotal: $\(tableTotal, specifier: "%.2f")").font(.caption)
                    }
                }

                // ✅ Clear price breakdown
                Section(header: Text("Order Summary")) {
                    HStack {
                        Text("Subtotal")
                        Spacer()
                        Text("$\(subTotal, specifier: "%.2f")")
                    }
                    HStack {
                        Text("Platform Fee (5%)")
                        Spacer()
                        Text("$\(platformFee, specifier: "%.2f")")
                    }
                    HStack {
                        Text("Total")
                            .font(.headline)
                        Spacer()
                        Text("$\(totalWithFee, specifier: "%.2f")")
                            .font(.headline)
                    }
                }

                // Action
                if ticketQty > 0 || tableQty > 0 {
                    Button(subTotal == 0 ? "Claim Free Tickets" : "Proceed to Payment") {
                        presentationMode.wrappedValue.dismiss()
                        if subTotal == 0 {
                            // No fee on $0 orders
                            claimFreeTickets(ticketQty: ticketQty, tableQty: tableQty)
                        } else {
                            onConfirm?(ticketQty, tableQty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                } else {
                    Text("Select at least one item to continue.")
                        .foregroundColor(.gray)
                        .font(.caption)
                        .padding(.top, 10)
                }

                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.red)
            }
            .navigationTitle("Confirm Purchase")
        }
    }

    // Keep your free-claim flow unchanged
    func claimFreeTickets(ticketQty: Int, tableQty: Int) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let db = Database.database().reference()
        let timestamp = Date().timeIntervalSince1970

        if ticketQty > 0 {
            let ticketRef = db.child("purchases").child(userId).childByAutoId()
            let data: [String: Any] = [
                "eventId": event.id,
                "eventTitle": event.title,
                "eventImagePath": event.imagePath,
                "quantity": ticketQty,
                "type": "ticket",
                "totalAmount": 0.0,
                "timestamp": timestamp
            ]
            ticketRef.setValue(data)
            db.child("events").child(event.id).child("ticketsSold").runTransactionBlock { currentData in
                let current = currentData.value as? Int ?? 0
                currentData.value = current + ticketQty
                return TransactionResult.success(withValue: currentData)
            }
        }

        if tableQty > 0 {
            let tableRef = db.child("purchases").child(userId).childByAutoId()
            let data: [String: Any] = [
                "eventId": event.id,
                "eventTitle": event.title,
                "eventImagePath": event.imagePath,
                "quantity": tableQty,
                "type": "table",
                "totalAmount": 0.0,
                "timestamp": timestamp
            ]
            tableRef.setValue(data)
            db.child("events").child(event.id).child("tablesSold").runTransactionBlock { currentData in
                let current = currentData.value as? Int ?? 0
                currentData.value = current + tableQty
                return TransactionResult.success(withValue: currentData)
            }
        }
    }

    // Helpers
    private func round2(_ x: Double) -> Double {
        (x * 100).rounded() / 100
    }
}
