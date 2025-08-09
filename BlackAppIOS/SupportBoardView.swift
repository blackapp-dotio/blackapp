import SwiftUI
import FirebaseDatabase

struct SupportBoardView: View {
    @State private var selectedStatus = "Unread"
    @State private var supportMessages: [SupportMessage] = []
    @State private var selectedMessage: SupportMessage?

    let statuses = ["Unread", "Backlog", "Started", "In Progress", "Resolved"]

    var body: some View {
        VStack {
            // MARK: - Status Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(statuses, id: \.self) { status in
                        Button(action: {
                            selectedStatus = status
                        }) {
                            Text(status)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(selectedStatus == status ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
                                .foregroundColor(selectedStatus == status ? .blue : .primary)
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            // MARK: - Filtered Message List
            List {
                ForEach(supportMessages.filter { $0.status == selectedStatus }) { message in
                    Button {
                        selectedMessage = message
                    } label: {
                        VStack(alignment: .leading) {
                            Text(message.text)
                                .font(.body)
                                .lineLimit(2)
                            Text("From: \(message.name) (\(message.email))")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
        }
        .sheet(item: $selectedMessage) { message in
            SupportMessageDetailView(message: message, onUpdate: { newStatus in
                updateSupportMessageStatus(messageId: message.id, newStatus: newStatus)
            })
        }
        .onAppear {
            fetchSupportMessages()
        }
    }

    // MARK: - Firebase Methods

    private func fetchSupportMessages() {
        let ref = Database.database().reference().child("supportMessages")
        ref.observeSingleEvent(of: .value) { snapshot in
            var messages: [SupportMessage] = []

            for case let child as DataSnapshot in snapshot.children {
                if let dict = child.value as? [String: Any],
                   let message = dict["message"] as? String,
                   let timestamp = dict["timestamp"] as? TimeInterval,
                   let userId = dict["userId"] as? String {
                    
                    let status = dict["status"] as? String ?? "Unread"
                    let name = dict["name"] as? String ?? "Unknown"
                    let email = dict["email"] as? String ?? "Unknown"
                    
                    messages.append(SupportMessage(
                        id: child.key,
                        userId: userId,
                        text: message,
                        timestamp: timestamp,
                        name: name,
                        email: email,
                        status: status
                    ))
                }
            }

            DispatchQueue.main.async {
                self.supportMessages = messages.sorted { $0.timestamp > $1.timestamp }
            }
        }
    }

    private func updateSupportMessageStatus(messageId: String, newStatus: String) {
        let ref = Database.database().reference().child("supportMessages").child(messageId)
        ref.updateChildValues(["status": newStatus]) { error, _ in
            if let error = error {
                print("❌ Failed to update status: \(error.localizedDescription)")
            } else {
                print("✅ Support message status updated to: \(newStatus)")
                fetchSupportMessages()
            }
        }
    }
}


struct SupportMessageDetailView: View {
    let message: SupportMessage
    var onUpdate: (String) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var selectedStatus: String

    let statuses = ["Unread", "Backlog", "Started", "In Progress", "Resolved"]

    init(message: SupportMessage, onUpdate: @escaping (String) -> Void) {
        self.message = message
        self.onUpdate = onUpdate
        _selectedStatus = State(initialValue: message.status ?? "unread")
    }


    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Message")) {
                    Text(message.text)
                        .padding(.vertical)
                }

                Section(header: Text("From")) {
                    Text(message.name)
                    Text(message.email)
                        .font(.footnote)
                        .foregroundColor(.gray)
                }

                Section(header: Text("Status")) {
                    Picker("Update Status", selection: $selectedStatus) {
                        ForEach(statuses, id: \.self) {
                            Text($0)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
            }
            .navigationTitle("Support Message")
            .navigationBarItems(trailing: Button("Save") {
                onUpdate(selectedStatus)
                dismiss()
            })
        }
    }
}
