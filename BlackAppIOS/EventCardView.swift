
import SwiftUI

struct EventCardView: View {
    let event: Event
    let selectedURL: Binding<URL?>
    let showWebView: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imageURLString = event.imageURL,
               let imageURL = URL(string: imageURLString) {
                AsyncImage(url: imageURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(10)
                } placeholder: {
                    Rectangle()
                        .foregroundColor(.gray.opacity(0.2))
                        .frame(height: 200)
                        .cornerRadius(10)
                }
            }

            Text(event.name)
                .font(.headline)
                .foregroundColor(.white)

            Text(event.dateFormatted)
                .font(.subheadline)
                .foregroundColor(.gray)

            if !event.location.isEmpty {
                Text("📍 \(event.location)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if !event.paymentLink.isEmpty {
                Button("Buy Now") {
                    if let url = URL(string: event.paymentLink) {
                        selectedURL.wrappedValue = url
                        showWebView.wrappedValue = true
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.black)
    }
}
