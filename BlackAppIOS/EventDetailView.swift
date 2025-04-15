import SwiftUI
import WebKit

struct EventDetailView: View {
    let event: Event
    @State private var showWebView = false
    @State private var selectedURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let imageURL = event.imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(12)
                    } placeholder: {
                        Rectangle()
                            .foregroundColor(.gray.opacity(0.3))
                            .frame(height: 200)
                            .cornerRadius(12)
                    }
                }

                Text(event.name)
                    .font(.title)
                    .bold()
                    .foregroundColor(.white)

                Text("📍 \(event.location)")
                    .foregroundColor(.orange)

                Text("📅 \(event.dateFormatted)")
                    .foregroundColor(.gray)

                Text(event.description)
                    .foregroundColor(.white)
                    .padding(.top, 8)

                if event.sellTickets {
                    Button("Buy Ticket - $\(event.ticketPrice)") {
                        if let url = URL(string: event.paymentLink) {
                            selectedURL = url
                            showWebView = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding(.top)
                }

                if event.sellTables {
                    Button("Book Table - $\(event.tablePrice)") {
                        if let url = URL(string: event.paymentLink) {
                            selectedURL = url
                            showWebView = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showWebView) {
            if let url = selectedURL {
                WebView(url: url)
                    .edgesIgnoringSafeArea(.all)
            }
        }
        .navigationTitle("Event Details")
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
