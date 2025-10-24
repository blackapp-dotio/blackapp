// ModerationKit.swift
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// 1) Types
public enum ReportTargetType: String { case post, comment, message, event, profile }
public enum ReportReason: String, CaseIterable {
    case harassment, nudity, hate, spam, illegal, other
}

// 2) Report API
@discardableResult
public func reportContent(targetType: ReportTargetType,
                          targetId: String,
                          reason: ReportReason,
                          details: String = "") async throws {
    guard let uid = Auth.auth().currentUser?.uid else { return }
    try await Firestore.firestore().collection("reports").addDocument(data: [
        "targetType": targetType.rawValue,
        "targetId": targetId,
        "reportedBy": uid,
        "reason": reason.rawValue,
        "details": details,
        "createdAt": FieldValue.serverTimestamp(),
        "autoHidden": false
    ])
}

// 3) Block API
@discardableResult
public func blockUser(_ otherUid: String) async throws {
    guard let uid = Auth.auth().currentUser?.uid, uid != otherUid else { return }
    try await Firestore.firestore()
        .collection("users").document(uid)
        .collection("blocks").document(otherUid)
        .setData(["blocked": true, "createdAt": FieldValue.serverTimestamp()], merge: true)
}

public func canBlock(_ otherUid: String) -> Bool {
    guard let me = Auth.auth().currentUser?.uid else { return false }
    return me != otherUid
}

// 4) Simple profanity/abuse guard (client side)
public struct ProfanityFilter {
    // Replace with your list; keep it small for now to avoid perf hits.
    public static let banned: [String] = [
        "nigga","nigger","kill yourself","nazi","suicide",
    ]
    public static func containsBanned(_ text: String) -> Bool {
        let lower = text.lowercased()
        return banned.contains(where: { lower.contains($0) })
    }
}

// 5) Report Flow (sheet UI)
public struct ReportSheet: View {
    public let targetType: ReportTargetType
    public let targetId: String
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .harassment
    @State private var details = ""
    @State private var sending = false
    @State private var error: String?
    @State private var sent = false

    public init(targetType: ReportTargetType, targetId: String) {
        self.targetType = targetType
        self.targetId = targetId
    }

    public var body: some View {
        NavigationView {
            Form {
                Picker("Reason", selection: $reason) {
                    ForEach(ReportReason.allCases, id: \.self) { r in
                        Text(r.rawValue.capitalized).tag(r)
                    }
                }
                Section("Details (optional)") { TextEditor(text: $details).frame(minHeight: 100) }
                if let error { Text(error).foregroundColor(.red) }
                if sent { Text("Report sent. We review within 24 hours.").foregroundColor(.green) }
            }
            .navigationTitle("Report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : "Send") { Task { await submit() } }
                        .disabled(sending || sent)
                }
            }
        }
    }

    private func submit() async {
        sending = true; error = nil
        do {
            try await reportContent(targetType: targetType, targetId: targetId, reason: reason, details: details)
            sent = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            self.error = "Could not send report. Try again."
        }
        sending = false
    }
}

// 6) Reusable icon overlays (post/profile) and header actions (chat)
public struct PostModerationOverlay: View {
    public let authorUid: String
    public let targetId: String
    public let targetType: ReportTargetType
    @State private var showReport = false
    @State private var showBlockConfirm = false
    @State private var isBlocking = false
    @State private var blockedDone = false
    @State private var error: String?

    public init(authorUid: String, targetId: String, targetType: ReportTargetType) {
        self.authorUid = authorUid; self.targetId = targetId; self.targetType = targetType
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button {
                showReport = true; UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Circle().fill(Color.black.opacity(0.55)).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "flag.fill").foregroundColor(.white).font(.system(size: 14, weight: .semibold)))
                    .accessibilityLabel("Report")
            }
            if canBlock(authorUid) {
                Button {
                    showBlockConfirm = true; UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Circle().fill(Color.black.opacity(0.55)).frame(width: 32, height: 32)
                        .overlay(Image(systemName: "person.crop.circle.badge.xmark").foregroundColor(.white).font(.system(size: 15, weight: .semibold)))
                        .accessibilityLabel("Block user")
                }
                .confirmationDialog("Block this user?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
                    Button(blockedDone ? "Blocked" : "Block User", role: .destructive) {
                        Task { await doBlock() }
                    }.disabled(blockedDone || isBlocking)
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .padding(.top, 8).padding(.trailing, 8)
        .sheet(isPresented: $showReport) {
            ReportSheet(targetType: targetType, targetId: targetId)
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func doBlock() async {
        isBlocking = true; error = nil
        do { try await blockUser(authorUid); blockedDone = true } catch { self.error = "Could not block. Try again." }
        isBlocking = false
    }
}

public struct ChatHeaderActions: View {
    public let otherUid: String?   // nil for groups (no block)
    public let targetId: String    // threadId / groupId
    public let isGroup: Bool
    @State private var showReport = false
    @State private var showBlockConfirm = false
    @State private var isBlocking = false
    @State private var blockedDone = false
    @State private var error: String?

    public init(otherUid: String?, targetId: String, isGroup: Bool) {
        self.otherUid = otherUid; self.targetId = targetId; self.isGroup = isGroup
    }

    public var body: some View {
        HStack(spacing: 16) {
            Button { showReport = true; UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: {
                Image(systemName: "flag.fill").foregroundColor(.white)
            }
            .accessibilityLabel("Report")
            .sheet(isPresented: $showReport) {
                ReportSheet(targetType: .message, targetId: targetId)
            }

            if let other = otherUid, !isGroup, canBlock(other) {
                Button { showBlockConfirm = true; UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: {
                    Image(systemName: "person.crop.circle.badge.xmark").foregroundColor(.white)
                }
                .accessibilityLabel("Block user")
                .confirmationDialog("Block this user?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
                    Button(blockedDone ? "Blocked" : "Block User", role: .destructive) {
                        Task { await doBlock(other) }
                    }.disabled(blockedDone || isBlocking)
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func doBlock(_ other: String) async {
        isBlocking = true; error = nil
        do { try await blockUser(other); blockedDone = true } catch { self.error = "Could not block. Try again." }
        isBlocking = false
    }
}

public struct ProfileModerationBar: View {
    public let profileUid: String
    @State private var showReport = false
    @State private var showBlockConfirm = false

    public init(profileUid: String) { self.profileUid = profileUid }

    public var body: some View {
        HStack(spacing: 12) {
            Button { showReport = true; UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: {
                Image(systemName: "flag.fill").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
            }
            .sheet(isPresented: $showReport) { ReportSheet(targetType: .profile, targetId: profileUid) }

            if canBlock(profileUid) {
                Button { showBlockConfirm = true; UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: {
                    Image(systemName: "person.crop.circle.badge.xmark").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                }
                .confirmationDialog("Block this user?", isPresented: $showBlockConfirm) {
                    Button("Block User", role: .destructive) { Task { try? await blockUser(profileUid) } }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }
}
