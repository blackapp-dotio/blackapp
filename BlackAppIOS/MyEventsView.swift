import SwiftUI
import FirebaseAuth
import FirebaseDatabase

struct MyEventsView: View {
    @State private var myEvents: [Event] = []
    @State private var isLoading = true
    @State private var showEdit = false
    @State private var selectedEventToEdit: Event?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading your events...")
                        .padding()
                } else if myEvents.isEmpty {
                    Text("You haven’t created any events yet.")
                        .foregroundColor(.gray)
                        .padding()
                } else {
                    List {
                        ForEach(myEvents.sorted(by: { $0.date > $1.date })) { event in
                            VStack(alignment: .leading, spacing: 8) {
                                if let imageURL = event.imageURL, let url = URL(string: imageURL) {
                                    AsyncImage(url: url) { image in
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: 180)
                                            .cornerRadius(10)
                                    } placeholder: {
                                        Rectangle()
                                            .foregroundColor(.gray.opacity(0.3))
                                            .frame(height: 180)
                                            .cornerRadius(10)
                                    }
                                }

                                Text(event.name)
                                    .font(.headline)
                                    .foregroundColor(.white)

                                Text("📅 " + event.dateFormatted)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)

                                HStack {
                                    Button {
                                        selectedEventToEdit = event
                                        showEdit = true
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                            .foregroundColor(.blue)
                                    }

                                    Spacer()

                                    Button(role: .destructive) {
                                        deleteEvent(event)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(Color.black)
                        }
                    }
                    .listStyle(.plain)
                    .background(Color.black)
                }
            }
            .navigationTitle("My Events")
            .onAppear {
                fetchUserEvents()
            }
            .sheet(isPresented: $showEdit) {
                if let event = selectedEventToEdit {
                    EditEventView(event: event, isPresented: $showEdit)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    func fetchUserEvents() {
        guard let userId = Auth.auth().currentUser?.uid else { return }

        let ref = Database.database().reference().child("events")
        ref.observeSingleEvent(of: .value) { snapshot in
            var loaded: [Event] = []

            for case let child as DataSnapshot in snapshot.children {
                if let event = Event.from(snapshot: child), event.userId == userId {
                    loaded.append(event)
                }
            }

            DispatchQueue.main.async {
                self.myEvents = loaded
                self.isLoading = false
            }
        }
    }

    func deleteEvent(_ event: Event) {
        let ref = Database.database().reference().child("events").child(event.id)
        ref.removeValue()
        myEvents.removeAll { $0.id == event.id }
    }
}
