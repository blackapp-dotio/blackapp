// PhoneLoginView.swift
import SwiftUI
import FirebaseAuth

struct PhoneLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var verificationID: String?
    @State private var phase: Phase = .enterPhone
    @State private var error: String?
    @State private var working = false
    @AppStorage("acceptedEULA_v1") private var acceptedEULA = false
    @State private var showEULA = false

    enum Phase { case enterPhone, enterCode }

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {
                if phase == .enterPhone {
                    TextField("+1 555 123 4567", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                        .foregroundColor(.white)
                        .padding(.horizontal)

                    Button("Send Code") { Task { await sendCode() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || phone.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    SecureField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                        .foregroundColor(.white)
                        .padding(.horizontal)

                    Button("Verify & Sign In") { Task { await verify() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || code.count < 6)
                }

                if working { ProgressView().tint(.white) }
                if let error { Text(error).foregroundColor(.red).font(.footnote) }

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Phone Sign In")
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } } }
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
    }

    private func sendCode() async {
        await MainActor.run { working = true; error = nil }
        do {
            let id = try await PhoneAuthProvider.provider().verifyPhoneNumber(phone, uiDelegate: nil)
            await MainActor.run {
                self.verificationID = id
                self.phase = .enterCode
                self.working = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.working = false
            }
        }
    }

    private func verify() async {
        guard let id = verificationID else { return }
        await MainActor.run { working = true; error = nil }
        do {
            let credential = PhoneAuthProvider.provider().credential(withVerificationID: id, verificationCode: code)
            _ = try await Auth.auth().signIn(with: credential) // or link: Auth.auth().currentUser?.link(with: credential)
            await MainActor.run {
                working = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.working = false
            }
        }
    }
}
