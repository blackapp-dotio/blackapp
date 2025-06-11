import SwiftUI

struct CheckoutConfirmationView: View {
    let event: EventModel
    var onConfirm: (Int, Int) -> Void
    @Environment(\.presentationMode) var presentationMode

    @State private var ticketQty = 0
    @State private var tableQty = 0

    var ticketTotal: Double {
        Double(ticketQty) * event.ticketPrice
    }

    var tableTotal: Double {
        Double(tableQty) * event.tablePrice
    }

    var totalWithFee: Double {
        (ticketTotal + tableTotal) * 1.02
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Select Quantities")) {
                    if event.ticketPrice > 0 && event.ticketQuantity > 0 {
                        Stepper("Tickets (\(ticketQty))", value: $ticketQty, in: 0...event.ticketQuantity)
                        Text("Subtotal: $\(ticketTotal, specifier: "%.2f")")
                            .font(.caption)
                    }

                    if event.tablePrice > 0 && event.tableQuantity > 0 {
                        Stepper("Tables (\(tableQty))", value: $tableQty, in: 0...event.tableQuantity)
                        Text("Subtotal: $\(tableTotal, specifier: "%.2f")")
                            .font(.caption)
                    }
                }

                Section(header: Text("Total with 2% Platform Fee")) {
                    Text("$\(totalWithFee, specifier: "%.2f")")
                        .font(.title2)
                        .bold()
                }

                if ticketQty > 0 || tableQty > 0 {
                    Button("Proceed to Payment") {
                        presentationMode.wrappedValue.dismiss()
                        onConfirm(ticketQty, tableQty)
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
}
