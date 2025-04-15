import SwiftUI
import SafariServices

struct HostedCheckoutView: View {
    @State private var showCheckout = false
    @State private var checkoutURL: URL?

    let amount: Double
    let description: String

    var body: some View {
        VStack(spacing: 20) {
            Text("Complete Your Purchase")
                .font(.title2)

            Button("Buy Now - $\(String(format: "%.2f", amount))") {
                fetchCheckoutURL()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .padding()
        .sheet(isPresented: $showCheckout) {
            if let url = checkoutURL {
                SafariView(url: url)
            }
        }
    }

    func fetchCheckoutURL() {
        let baseURL = "https://us-central1-BlackAppIOS.cloudfunctions.net/getCheckoutURL"
        guard var components = URLComponents(string: baseURL) else { return }

        components.queryItems = [
            URLQueryItem(name: "amount", value: String(amount)),
            URLQueryItem(name: "description", value: description)
        ]

        guard let url = components.url else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let result = try? JSONDecoder().decode([String: String].self, from: data),
                  let redirect = result["checkoutURL"],
                  let url = URL(string: redirect) else { return }

            DispatchQueue.main.async {
                self.checkoutURL = url
                self.showCheckout = true
            }
        }.resume()
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        return SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
