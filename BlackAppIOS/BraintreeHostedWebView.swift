import SwiftUI
import WebKit

struct BraintreeHostedWebView: UIViewRepresentable {
    let amount: Double
    let eventName: String
    let onSuccess: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator

        // Replace with your actual hosted payment page link
        let encodedName = eventName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Event"
        let urlString = "https://blackappios.web.app/?amount=\(amount)&desc=\(encodedName)"
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No updates needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onSuccess: () -> Void

        init(onSuccess: @escaping () -> Void) {
            self.onSuccess = onSuccess
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // You can inspect the URL for success indicator
            if let currentURL = webView.url?.absoluteString {
                if currentURL.contains("success") {
                    print("✅ Payment success detected")
                    onSuccess()
                }
            }
        }
    }
}
