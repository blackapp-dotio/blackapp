// FirebaseHTTP.swift
import Foundation
import FirebaseAppCheck

enum FirebaseHTTP {

    /// Get an App Check token (defaulted so call sites don’t need to pass it).
    static func appCheckToken(forcingRefresh: Bool = false) async -> String? {
        do {
            let t = try await AppCheck.appCheck().token(forcingRefresh: forcingRefresh)
            return t.token
        } catch {
            return nil
        }
    }

    /// POST JSON and automatically attach the App Check header if available.
    static func postJSON(to url: URL, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        if let token = await appCheckToken() {
            req.setValue(token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
