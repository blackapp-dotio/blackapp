// EULAGateView.swift
import SwiftUI
import SafariServices

struct EULAGateView: View {
    @AppStorage("acceptedEULA_v1") private var accepted = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to BlackApp")
                .font(.title).bold().foregroundColor(.white)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Please review and accept our Terms and Privacy Policy to continue.")
                        .foregroundColor(.white)

                    HStack(spacing: 16) {
                        LinkButton(title: "Terms of Service", urlString: "https://blackapp.io/terms")
                        LinkButton(title: "Privacy Policy", urlString: "https://blackapp.io/privacy")
                    }

                    Text("Key Points")
                        .font(.headline).foregroundColor(.white).padding(.top, 8)
                    bullet("User-generated content is visible to others unless you set it otherwise.")
                    bullet("You can block or report users/content at any time.")
                    bullet("You can delete your account at any time from Settings.")
                }
                .padding(.horizontal)
            }

            Button(action: { accepted = true }) {
                Text("I Agree & Continue")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)

            Spacer(minLength: 8)
        }
        .padding(.top, 24)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundColor(.white)
            Text(text).foregroundColor(.gray)
        }
    }
}

private struct LinkButton: View {
    let title: String
    let urlString: String
    var body: some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                Text(title)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                    .foregroundColor(.white)
            }
        } else {
            Text(title).foregroundColor(.gray)
        }
    }
}
