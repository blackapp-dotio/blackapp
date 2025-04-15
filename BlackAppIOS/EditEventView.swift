import SwiftUI
import FirebaseAuth
import FirebaseStorage
import FirebaseDatabase

struct EditEventView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var isPresented: Bool

    var event: Event

    @State private var eventName: String
    @State private var eventDescription: String
    @State private var eventDate: Date
    @State private var ticketPrice: String
    @State private var tablePrice: String
    @State private var ticketQuantity: String
    @State private var tableQuantity: String
    @State private var paymentLink: String
    @State private var location: String
    @State private var isSubmitting = false

    init(event: Event, isPresented: Binding<Bool>) {
        self.event = event
        _isPresented = isPresented
        _eventName = State(initialValue: event.name)
        _eventDescription = State(initialValue: event.description)
        _eventDate = State(initialValue: Date(timeIntervalSince1970: event.date))
        _ticketPrice = State(initialValue: event.ticketPrice ?? "")
        _tablePrice = State(initialValue: event.tablePrice ?? "")
        _ticketQuantity = State(initialValue: event.ticketQuantity ?? "")
        _tableQuantity = State(initialValue: event.tableQuantity ?? "")
        _paymentLink = State(initialValue: event.paymentLink ?? "")
        _location = State(initialValue: event.location ?? "")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Edit Event")
                        .font(.title)
                        .bold()

                    TextField("Event Name", text: $eventName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    TextEditor(text: $eventDescription)
                        .frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray))

                    DatePicker("Event Date", selection: $eventDate, displayedComponents: [.date, .hourAndMinute])

                    TextField("Location", text: $location)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    TextField("Ticket Price (USD)", text: $ticketPrice)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    TextField("Number of Tickets", text: $ticketQuantity)
                        .keyboardType(.numberPad)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    TextField("Table Price (USD)", text: $tablePrice)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    TextField("Number of Tables", text: $tableQuantity)
                        .keyboardType(.numberPad)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    TextField("Payment Link", text: $paymentLink)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    Button(action: updateEvent) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Save Changes")
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
            .navigationBarTitle("Edit Event", displayMode: .inline)
            .preferredColorScheme(.dark)
        }
    }

    func updateEvent() {
        guard !eventName.isEmpty, !eventDescription.isEmpty else { return }
        isSubmitting = true

        let ref = Database.database().reference().child("events").child(event.id)
        var updatedData: [String: Any] = [
            "name": eventName,
            "description": eventDescription,
            "date": eventDate.timeIntervalSince1970,
            "ticketPrice": ticketPrice,
            "tablePrice": tablePrice,
            "ticketQuantity": ticketQuantity,
            "tableQuantity": tableQuantity,
            "paymentLink": paymentLink,
            "location": location
        ]

        ref.updateChildValues(updatedData) { error, _ in
            isSubmitting = false
            if error == nil {
                isPresented = false
            }
        }
    }
}
