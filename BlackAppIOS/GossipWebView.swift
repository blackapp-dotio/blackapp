
//
//  GossipWebView.swift
//  BlackAppIOS
//

import SwiftUI
import WebKit
import UIKit
import Foundation

struct GossipWebView: View {
    let url: URL
    @State private var loading = true
    @State private var progress: Double = 0.0
    @State private var lastError: NSError?
    @Environment(\.dismiss) private var dismiss   // ← add this

    var body: some View {
        ZStack {
            InnerWebView(url: url, loading: $loading, progress: $progress, lastError: $lastError)

            // 🔽 Pull-down hint / tap-to-dismiss
            VStack(spacing: 6) {
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
                HStack(spacing: 4) {
                    Image(systemName: "chevron.compact.down")
                    Text("Pull down to close")
                }
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.0001)) // keep touches
            .onTapGesture { dismiss() }               // tap also closes
            .padding(.top, 6)
            .frame(maxHeight: .infinity, alignment: .top)

            if loading {
                VStack(spacing: 10) {
                    ProgressView(value: progress == 0 ? nil : progress)
                    Text("Loading…").font(.footnote).foregroundColor(.white.opacity(0.9))
                }
                .padding(12)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity)
            }

            if let err = lastError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").imageScale(.large)
                    Text(err.localizedDescription.isEmpty ? "Failed to load page" : err.localizedDescription)
                        .font(.callout).multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Reload") {
                            lastError = nil
                            progress = 0
                            loading = true
                            NotificationCenter.default.post(name: .gossipWebViewReload, object: url)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open in Safari") {
                            UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .foregroundColor(.white)
                .background(Color.black.opacity(0.6))
                .cornerRadius(12)
                .padding()
                .transition(.opacity)
            }
        }
        .background(Color.black)
    }


    fileprivate struct InnerWebView: UIViewRepresentable {
        let url: URL
        @Binding var loading: Bool
        @Binding var progress: Double
        @Binding var lastError: NSError?

        func makeCoordinator() -> Coordinator {
            Coordinator(loading: $loading, progress: $progress, lastError: $lastError, originalURL: url)
        }

        func makeUIView(context: Context) -> WKWebView {
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true

            let cfg = WKWebViewConfiguration()
            cfg.defaultWebpagePreferences = prefs
            cfg.allowsInlineMediaPlayback = true

            let wv = WKWebView(frame: .zero, configuration: cfg)
            wv.isOpaque = false
            wv.backgroundColor = .black
            wv.navigationDelegate = context.coordinator
            wv.uiDelegate = context.coordinator
            wv.allowsBackForwardNavigationGestures = true

            // progress KVO
            context.coordinator.kvo = wv.observe(\.estimatedProgress, options: [.new]) { _, change in
                DispatchQueue.main.async {
                    progress = change.newValue ?? 0
                }
            }

            // initial load
            context.coordinator.load(in: wv, url: url)

            // listen for reload requests
            context.coordinator.reloadObserver = NotificationCenter.default.addObserver(
                forName: .gossipWebViewReload, object: nil, queue: .main
            ) { note in
                guard let target = note.object as? URL, target == url else { return }
                context.coordinator.load(in: wv, url: url)
            }

            return wv
        }

        func updateUIView(_ webView: WKWebView, context: Context) { /* no-op */ }

        static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
            if let o = coordinator.kvo { o.invalidate() }
            if let ro = coordinator.reloadObserver { NotificationCenter.default.removeObserver(ro) }
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
            @Binding var loading: Bool
            @Binding var progress: Double
            @Binding var lastError: NSError?
            let originalURL: URL
            var kvo: NSKeyValueObservation?
            var reloadObserver: NSObjectProtocol?

            init(loading: Binding<Bool>, progress: Binding<Double>, lastError: Binding<NSError?>, originalURL: URL) {
                _loading = loading; _progress = progress; _lastError = lastError
                self.originalURL = originalURL
            }

            func load(in webView: WKWebView, url: URL) {
                lastError = nil
                loading = true
                progress = 0

                // ATS-friendly: if it's http, prefer opening in Safari (fallback)
                if url.scheme?.lowercased() == "http" {
                    loading = false
                    UIApplication.shared.open(url)
                    // Also set an error message to explain why it didn’t load inline
                    lastError = NSError(domain: "GossipWebView", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey:
                                                   "This site uses http:// which the app blocks. Opened in Safari instead."])
                    return
                }

                var req = URLRequest(url: url)
                req.timeoutInterval = 12.0
                webView.load(req)
            }

            // MARK: WKNavigationDelegate
            func webView(_ webView: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
                loading = true
            }

            func webView(_ webView: WKWebView, didCommit nav: WKNavigation!) {
                loading = false // content started arriving
            }

            func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
                loading = false
                progress = 1.0
            }

            func webView(_ webView: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
                loading = false
                lastError = error as NSError
            }

            func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
                loading = false
                lastError = error as NSError
            }

            /// Handle target=_blank / no target frame → load in the same webview
            func webView(_ webView: WKWebView,
                         decidePolicyFor navigationAction: WKNavigationAction,
                         decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

                if navigationAction.targetFrame == nil, let u = navigationAction.request.url {
                    webView.load(URLRequest(url: u)); decisionHandler(.cancel); return
                }
                decisionHandler(.allow)
            }

            // MARK: WKUIDelegate (window.open)
            func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                         for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
                // When a site tries to open a new window, just load in current view
                if let u = navigationAction.request.url {
                    webView.load(URLRequest(url: u))
                }
                return nil
            }
        }
    }
}

extension Notification.Name {
    static let gossipWebViewReload = Notification.Name("gossipWebViewReload")
}
