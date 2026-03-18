import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseDatabase

/// BlackAppMoney
/// - Reads:  RTDB users/{uid}/stripeAccountId + onboarding flags
/// - Writes: RTDB users/{uid}/stripeAccountId (manual paste or backend upsert)
/// - Opens:  Stripe Connect onboarding/login link returned by your backend
struct BlackAppMoneyView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var loading = true
    @State private var busy = false
    
    @State private var errorText: String?
    
    @State private var stripeAccountId: String = ""
    @State private var lastUpdatedAt: TimeInterval?
    
    // Platform Stripe account id (must NEVER be used as a seller destination)
    @State private var platformStripeAccountId: String = ""   // loaded from RTDB config
    
    // Flags mirrored from stripeWebhook -> users/{uid}
    @State private var stripeOnboardingComplete = false
    @State private var stripeChargesEnabled = false
    @State private var stripePayoutsEnabled = false
    
    // Optional “manual paste” flow if needed (useful during early testing)
    @State private var showManualPaste = false
    @State private var manualAcctInput = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        
                        header
                        statusCard
                        actionCard
                        helpCard
                        
                        if let err = errorText {
                            Text(err)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .padding(.top, 6)
                        }
                        
                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
                
                if busy {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView("Working…")
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(14)
                    }
                }
            }
            .navigationTitle("BlackAppMoney")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.white)
                    }
                    .disabled(busy)
                }
            }
            .task { await refresh() }
            .sheet(isPresented: $showManualPaste) {
                manualPasteSheet
            }
            .alert("BlackAppMoney", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }
    
    // MARK: - Derived State
    
    private var isConnected: Bool {
        !stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var isLive: Bool {
        isConnected && stripeChargesEnabled && stripePayoutsEnabled
    }
    
    private var isPendingActivation: Bool {
        isConnected && !isLive
    }
    
    // MARK: - UI Blocks
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get paid through BlackApp.")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("BlackApp supports instant payouts and international transfers via Stripe.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.bottom, 6)
    }
    
    private var statusCard: some View {
        // Build a friendly explanation for “connected but not live” states
        let reasonDescription: String = {
            var parts: [String] = []
            if isConnected && !stripeChargesEnabled {
                parts.append("charges are not yet enabled")
            }
            if isConnected && !stripePayoutsEnabled {
                parts.append("payouts are not yet enabled")
            }
            if parts.isEmpty {
                return "Stripe still needs a bit more information to activate your account."
            }
            if parts.count == 1 {
                return parts[0].capitalized + "."
            }
            return parts.joined(separator: " and ").capitalized + "."
        }()
        
        let iconName: String
        let iconColor: Color
        let titleText: String
        let subtitleText: String
        
        if isLive {
            iconName = "checkmark.seal.fill"
            iconColor = .green
            titleText = "Stripe Connected & Live"
            subtitleText = "Payouts are enabled. New ticket and table sales will route directly to your Stripe account."
        } else if isPendingActivation {
            iconName = "exclamationmark.triangle.fill"
            iconColor = .yellow
            titleText = "Stripe Connected – Action Needed"
            subtitleText = "Your Stripe account is linked, but \(reasonDescription) Open Stripe below to finish onboarding."
        } else {
            iconName = "exclamationmark.triangle.fill"
            iconColor = .yellow
            titleText = "Not Connected"
            subtitleText = "Connect Stripe so you can receive payouts for ticket and table sales."
        }
        
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                
                Text(titleText)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
            }
            
            if isConnected {
                Text("Account: \(stripeAccountId)")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.75))
                    .textSelection(.enabled)
                
                if let ts = lastUpdatedAt {
                    Text("Updated: \(formatTS(ts))")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            
            Text(subtitleText)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
    }
    
    private var actionCard: some View {
        let primaryLabel = isLive ? "Open Stripe Dashboard" : "Connect Stripe Account"
        let secondaryLabel = isLive ? "Manage Stripe Details" : "Get a Stripe Account"
        
        return VStack(alignment: .leading, spacing: 12) {
            Text("Payout Setup")
                .font(.headline)
                .foregroundColor(.white)
            
            // CTA 1: Connect / Open Stripe
            Button {
                Task { await openStripeOnboarding(primaryCTA: true) }
            } label: {
                HStack {
                    Image(systemName: "link")
                    Text(primaryLabel)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.system(size: 16, weight: .semibold))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.10))
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .disabled(busy)
            
            Button {
                Task { await resetStripeLink() }
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset Stripe Link (if you deleted your account)")
                    Spacer()
                }
                .font(.system(size: 14, weight: .semibold))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.18))
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .disabled(busy)
            // CTA 2: Get a Stripe Account (for users that don't have one yet)
            Button {
                Task { await openStripeOnboarding(primaryCTA: false) }
            } label: {
                HStack {
                    Image(systemName: "person.badge.plus")
                    Text(secondaryLabel)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.system(size: 16, weight: .semibold))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.06))
                .foregroundColor(.white.opacity(0.92))
                .cornerRadius(14)
            }
            .disabled(busy)
            
            Divider().background(Color.white.opacity(0.12))
            
            // Optional: Manual paste (useful if you’re mid-migration/testing)
            Button {
                manualAcctInput = stripeAccountId
                showManualPaste = true
            } label: {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text("Paste Stripe Account ID (advanced)")
                    Spacer()
                }
                .font(.footnote)
                .padding(.top, 4)
                .foregroundColor(.white.opacity(0.75))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
    }
    
    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How payouts work (simple)")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("""
1) You connect Stripe once.
2) When customers buy tickets/tables, Stripe routes the payout to your connected account.
3) BlackApp collects a platform fee from the buyer automatically.
""")
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.75))
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(16)
    }
    
    private var manualPasteSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Stripe Account ID")) {
                    TextField("acct_...", text: $manualAcctInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                
                Section {
                    Button("Save to Profile") {
                        Task { await saveStripeAccountIdManually() }
                    }
                    .disabled(busy)
                    
                    Button("Cancel", role: .cancel) {
                        showManualPaste = false
                    }
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Data
    
    @MainActor
    private func refresh() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorText = "You must be signed in."
            return
        }
        
        loading = true
        defer { loading = false }
        
        let db = Database.database().reference()
        
        // 1) Load user state
        let userRef = db.child("users").child(uid)
        await withCheckedContinuation { cont in
            userRef.observeSingleEvent(of: .value) { snap in
                let dict = snap.value as? [String: Any] ?? [:]
                
                self.stripeAccountId = (dict["stripeAccountId"] as? String) ?? ""
                self.lastUpdatedAt = (dict["stripeAccountUpdatedAt"] as? TimeInterval)
                
                self.stripeOnboardingComplete = (dict["stripeOnboardingComplete"] as? Bool) ?? false
                self.stripeChargesEnabled = (dict["stripeChargesEnabled"] as? Bool) ?? false
                self.stripePayoutsEnabled = (dict["stripePayoutsEnabled"] as? Bool) ?? false
                
                cont.resume()
            }
        }
        
        // 2) Load platform Stripe account id (config)
        // Recommended RTDB path: config/stripePlatformAccountId = "acct_..."
        let configRef = db.child("config").child("stripePlatformAccountId")
        await withCheckedContinuation { cont in
            configRef.observeSingleEvent(of: .value) { snap in
                let v = (snap.value as? String) ?? ""
                self.platformStripeAccountId = v.trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume()
            }
        }
        
        // 3) If user has mistakenly saved the platform acct, surface it clearly
        let acct = stripeAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !acct.isEmpty,
           !platformStripeAccountId.isEmpty,
           acct == platformStripeAccountId {
            errorText = "Your profile is currently set to BlackApp’s platform Stripe account. This is not allowed for payouts. Please reset and connect your own Stripe account."
        }
    }
    
    
    @MainActor
    private func saveStripeAccountIdManually() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorText = "You must be signed in."
            return
        }
        
        do {
            let acct = try validateConnectedAccountIdOrThrow(manualAcctInput)
            
            busy = true
            defer { busy = false }
            
            let uref = Database.database().reference().child("users").child(uid)
            let now = Date().timeIntervalSince1970
            
            let payload: [String: Any] = [
                "stripeAccountId": acct,
                "stripeAccountUpdatedAt": now,
                
                // If user is manually pasting, reset flags until webhook updates them
                "stripeOnboardingComplete": false,
                "stripeChargesEnabled": false,
                "stripePayoutsEnabled": false
            ]
            
            await withCheckedContinuation { cont in
                uref.updateChildValues(payload) { err, _ in
                    if let err = err {
                        self.errorText = "Couldn’t save: \(err.localizedDescription)"
                    } else {
                        self.stripeAccountId = acct
                        self.lastUpdatedAt = now
                        self.showManualPaste = false
                    }
                    cont.resume()
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
    
    
    private func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func validateConnectedAccountIdOrThrow(_ acctRaw: String) throws -> String {
        let acct = normalized(acctRaw)
        
        if acct.isEmpty { return acct } // allow clearing
        guard acct.hasPrefix("acct_") else {
            throw NSError(domain: "BlackAppMoney", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "That doesn’t look like a Stripe account id. It should start with acct_."
            ])
        }
        
        // Block platform acct id explicitly (prevents the “transfer_data[destination]” error later)
        if !platformStripeAccountId.isEmpty, acct == platformStripeAccountId {
            throw NSError(domain: "BlackAppMoney", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "You can’t use BlackApp’s platform Stripe account for payouts. Please connect your own Stripe account."
            ])
        }
        
        return acct
    }
    
    @MainActor
    private func resetStripeLink() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorText = "You must be signed in."
            return
        }
        
        busy = true
        defer { busy = false }
        
        let uref = Database.database().reference().child("users").child(uid)
        let now = Date().timeIntervalSince1970
        
        let payload: [String: Any] = [
            "stripeAccountId": "",
            "stripeAccountUpdatedAt": now,
            
            // Reset flags so UI clearly shows “Not Connected”
            "stripeOnboardingComplete": false,
            "stripeChargesEnabled": false,
            "stripePayoutsEnabled": false
        ]
        
        await withCheckedContinuation { cont in
            uref.updateChildValues(payload) { err, _ in
                if let err = err {
                    self.errorText = "Couldn’t reset Stripe link. \(err.localizedDescription)"
                } else {
                    self.stripeAccountId = ""
                    self.lastUpdatedAt = now
                }
                cont.resume()
            }
        }
    }
    
    // MARK: - Stripe Onboarding Entry
    
    /// This is where BlackAppMoney hands off to your backend to generate a Stripe Connect onboarding/login URL.
    /// Backend returns:
    /// - `url` (String): onboarding or login link
    /// - optional `stripeAccountId` (String)
    @MainActor
    private func openStripeOnboarding(primaryCTA: Bool) async {
        guard Auth.auth().currentUser?.uid != nil else {
            errorText = "You must be signed in."
            return
        }
        
        busy = true
        defer { busy = false }
        
        do {
            let result = try await StripeConnectLinkService.shared.fetchConnectURL(
                mode: primaryCTA ? .connectExisting : .getNewAccount
            )
            
            if let url = URL(string: result.url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                errorText = "Invalid onboarding link returned."
            }
            
            if let acct = result.stripeAccountId, acct.hasPrefix("acct_") {
                await upsertStripeAccountId(acct)
            }
            
        } catch {
            errorText = "Couldn’t start Stripe setup. \(error.localizedDescription)"
        }
    }
    
    @MainActor
    private func upsertStripeAccountId(_ acctRaw: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        do {
            let acct = try validateConnectedAccountIdOrThrow(acctRaw)
            
            let uref = Database.database().reference().child("users").child(uid)
            let now = Date().timeIntervalSince1970
            
            let payload: [String: Any] = [
                "stripeAccountId": acct,
                "stripeAccountUpdatedAt": now
            ]
            
            await withCheckedContinuation { cont in
                uref.updateChildValues(payload) { _, _ in cont.resume() }
            }
            
            self.stripeAccountId = acct
            self.lastUpdatedAt = now
        } catch {
            errorText = error.localizedDescription
        }
    }
    private func formatTS(_ t: TimeInterval) -> String {
        let d = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}
