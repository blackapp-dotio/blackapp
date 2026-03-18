import Foundation
import FirebaseAuth

final class StripeConnectLinkService {
    static let shared = StripeConnectLinkService()

    enum Mode: String { case connectExisting = "connectExisting", getNewAccount = "getNewAccount" }

    struct Result: Decodable {
        let ok: Bool
        let url: String
        let stripeAccountId: String?
        let error: String?
    }

    private init() {}

    /// Calls your backend to create a Stripe Connect onboarding or login link.
    /// IMPORTANT: Replace endpoint with your real Cloud Function URL.
    func fetchConnectURL(mode: Mode) async throws -> Result {
        guard let user = Auth.auth().currentUser else {
            throw NSError(domain: "BlackAppMoney", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }

        let token = try await user.getIDToken()
        let endpoint = "https://us-central1-blackappios.cloudfunctions.net/createStripeConnectLink" // 👈 implement this

        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "mode": mode.rawValue,
            "platform": "ios"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let txt = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "BlackAppMoney", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Server error (\(http.statusCode)). \(txt)"
            ])
        }

        let decoded = try JSONDecoder().decode(Result.self, from: data)
        if decoded.ok == false {
            throw NSError(domain: "BlackAppMoney", code: 400, userInfo: [
                NSLocalizedDescriptionKey: decoded.error ?? "Unknown error"
            ])
        }
        return decoded
    }
}
