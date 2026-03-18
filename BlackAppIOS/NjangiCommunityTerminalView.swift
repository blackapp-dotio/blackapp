import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import SafariServices
import WebKit
import UIKit

struct NjangiCommunityTerminalView: View {
    enum CommunitySection: String, CaseIterable {
        case chat = "Chat"
        case contribute = "Contribute"
        case vote = "Vote"
        case members = "Members"
    }
    
    struct CommunityMessage: Identifiable {
        let id: String
        let text: String
        let gifURL: String?
        let senderUid: String
        let senderName: String
        let senderPhotoURL: String?
        let senderPhotoPath: String?
        let replyToMessageId: String?
        let replyToSenderName: String?
        let replyPreview: String?
        let reactionCounts: [String: Int]
        let myReactionKeys: Set<String>
        let createdAt: Timestamp?
    }
    
    struct CommunityMember: Identifiable {
        let id: String
        let uid: String
        let name: String
        let role: String
        let photoURL: String?
        let photoPath: String?
        let joinedAt: Timestamp?
    }
    
    struct FundContribution: Identifiable {
        let id: String
        let amount: Double
        let currency: String
        let reason: String
        let contributorUid: String
        let contributorName: String
        let contributorEmail: String
        let createdAt: Timestamp?
    }
    
    struct WithdrawalRecord: Identifiable {
        let id: String
        let amount: Double
        let currency: String
        let feeAmount: Double
        let netAmount: Double
        let status: String
        let reason: String
        let withdrawToUid: String
        let approvedByUid: String
        let createdAt: Timestamp?
    }
    
    struct GovernanceEvent: Identifiable {
        let id: String
        let kind: String
        let title: String
        let detail: String
        let status: String?
        let timestamp: Date?
    }
    
    let groupId: String
    let groupTitle: String
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedSection: CommunitySection = .chat
    
    @FocusState private var isChatInputFocused: Bool
    @State private var groupName: String = ""
    @State private var crestPath: String?
    @State private var crestURL: URL?
    @State private var contributionPerRound: Double?
    @State private var currencyCode: String = "USD"
    @State private var statusText: String = ""
    
    @State private var loading = true
    @State private var errorText: String?
    
    @State private var showWebNjangi = false
    @State private var showWebActions = false
    @State private var shareInviteItems: [Any] = []
    @State private var showShareSheet = false
    @State private var inviteBusy = false
    @State private var copiedBanner = false
    
    @State private var showGIFPicker = false
    @State private var sendingMessage = false
    @State private var selectedReplyTarget: CommunityMessage?
    @State private var toastText: String?
    
    @State private var messages: [CommunityMessage] = []
    @State private var draftMessage: String = ""
    @State private var currentUserName: String = "Member"
    @State private var currentUserEmail: String = ""
    
    @State private var members: [CommunityMember] = []
    
    @State private var contributions: [FundContribution] = []
    @State private var withdrawals: [WithdrawalRecord] = []
    @State private var governanceEvents: [GovernanceEvent] = []
    
    @State private var contributionInput: String = ""
    @State private var contributionReason: String = ""
    @State private var contributionBusy = false
    
    @State private var messageListener: ListenerRegistration?
    @State private var membersListener: ListenerRegistration?
    @State private var contributionsListener: ListenerRegistration?
    @State private var withdrawalsListener: ListenerRegistration?
    @State private var ledgerListener: ListenerRegistration?
    @State private var disputesListener: ListenerRegistration?
    
    @State private var governanceLedgerRaw: [[String: Any]] = []
    @State private var governanceDisputesRaw: [[String: Any]] = []
    
    var body: some View {
        NavigationStack {
            ZStack {
                backgroundLayer
                
                if loading {
                    ProgressView("Loading community…")
                        .foregroundColor(.white)
                } else if let errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.yellow)
                        
                        Text("Couldn’t load community")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text(errorText)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        
                        Button("Close") { dismiss() }
                            .padding(.top, 6)
                    }
                } else {
                    VStack(spacing: 8) {
                        compactHeader
                        actionToolbar
                        activeSectionView
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .foregroundColor(.white)
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                
                
            }
        }
        .task {
            await loadTerminalData()
        }
        .onDisappear {
            removeListeners()
        }
        .sheet(isPresented: $showWebNjangi) {
            NjangiWebModal(groupId: groupId)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(activityItems: shareInviteItems)
        }
        .sheet(isPresented: $showGIFPicker) {
            GIFSuggestionPickerView(suggestions: suggestedGIFs) { gif in
                Task { await sendGIFMessage(urlString: gif.urlString) }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if copiedBanner {
                    bannerChip(text: "Invite link copied")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let toastText {
                    bannerChip(text: toastText)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 24)
        }
    }
    
    private func bannerChip(text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white))
    }
    
    // MARK: Background
    
    private var backgroundLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.06, green: 0.09, blue: 0.14),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: 220, height: 220)
                .blur(radius: 40)
                .offset(x: -120, y: -260)
            
            Circle()
                .fill(Color.blue.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 55)
                .offset(x: 130, y: -180)
        }
    }
    
    // MARK: Header
    
    private var compactHeader: some View {
        HStack(spacing: 10) {
            crestView
                .frame(width: 48, height: 48)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(groupName.isEmpty ? groupTitle : groupName)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                if let amt = contributionPerRound, amt > 0 {
                    Text("Round contribution: \(currencyCode.uppercased()) \(formatAmount(amt))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                } else if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                } else {
                    Text("Simplified community terminal")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(glassCard)
        .overlay(glowStroke)
    }
    
    
    private var crestView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14),
                            Color.gray.opacity(0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            if let crestURL {
                AsyncImage(url: crestURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().tint(.white)
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(4)
                    default:
                        initialsFallback
                    }
                }
            } else {
                initialsFallback
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
    
    private var initialsFallback: some View {
        Text(initials(from: groupName.isEmpty ? groupTitle : groupName))
            .font(.headline.bold())
            .foregroundColor(.white)
    }
    
    // MARK: Top Toolbar
    
    private var actionToolbar: some View {
        HStack(spacing: 8) {
            sectionChip(.chat, icon: "bubble.left.and.bubble.right.fill")
            sectionChip(.contribute, icon: "dollarsign.circle.fill")
            sectionChip(.vote, icon: "checkmark.seal.fill")
            sectionChip(.members, icon: "person.3.fill")
            
            Spacer(minLength: 6)
            
            Button {
                showWebActions = true
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.gray)
                    .padding(10)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .confirmationDialog("Community Web Actions", isPresented: $showWebActions, titleVisibility: .visible) {
                Button("Open Web App") {
                    showWebNjangi = true
                }
                
                Button("Share Invite Link") {
                    Task { await prepareInviteLinkForSharing() }
                }
                
                Button("Copy Invite Link") {
                    Task { await copyInviteLinkToClipboard() }
                }
                
                Button("Cancel", role: .cancel) { }
            }
        }
        .padding(10)
        .background(glassCard)
        .overlay(glowStroke)
    }
    
    private func sectionChip(_ section: CommunitySection, icon: String) -> some View {
        let active = selectedSection == section
        
        return Button {
            selectedSection = section
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                
                Text(section.rawValue)
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .foregroundColor(active ? .black : .white)
            .frame(width: 70, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(active ? Color.white : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(active ? Color.white.opacity(0.85) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: active ? Color.white.opacity(0.18) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: Active Content
    
    @ViewBuilder
    private var activeSectionView: some View {
        switch selectedSection {
        case .chat:
            communityChatPanel
        case .contribute:
            contributePanel
        case .vote:
            votePanel
        case .members:
            membersPanel
        }
    }
    
    @ViewBuilder
    private func chatToolChip(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.bold())
            Text(label)
                .font(.caption.bold())
        }
        .foregroundColor(.gray)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
    
    // MARK: Chat Panel
    
    private var communityChatPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Community Chat")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("Live")
                    .font(.caption2.bold())
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty {
                            Text("No messages yet. Start the conversation.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .padding(.top, 24)
                        } else {
                            ForEach(messages) { message in
                                CommunityMessageBubble(
                                    message: CommunityMessageRow(
                                        id: message.id,
                                        senderName: message.senderName,
                                        senderUid: message.senderUid,
                                        senderPhotoURL: message.senderPhotoURL,
                                        senderPhotoPath: message.senderPhotoPath,
                                        text: message.text,
                                        gifURL: message.gifURL,
                                        replyToSenderName: message.replyToSenderName,
                                        replyPreview: message.replyPreview,
                                        reactionCounts: message.reactionCounts,
                                        myReactionKeys: message.myReactionKeys,
                                        isCurrentUser: message.senderUid == Auth.auth().currentUser?.uid,
                                        timestampText: timestampText(from: message.createdAt),
                                        createdAt: message.createdAt
                                    ),
                                    onReplyTap: {
                                        selectedReplyTarget = message
                                    },
                                    onReactTap: { key in
                                        Task { await toggleReaction(for: message, key: key) }
                                    }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    isChatInputFocused = false
                }
                .onChange(of: messages.count) { _ in
                    if let lastId = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
                .overlay(Color.white.opacity(0.08))
            
            VStack(spacing: 10) {
                if let selectedReplyTarget {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Replying to \(selectedReplyTarget.senderName)")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                            Text(previewText(for: selectedReplyTarget))
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Button {
                            self.selectedReplyTarget = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                }
                
                HStack(spacing: 8) {
                    Menu {
                        ForEach(quickComposerEmojis, id: \.self) { emoji in
                            Button("Add \(emoji)") {
                                draftMessage += draftMessage.isEmpty ? emoji : " \(emoji)"
                            }
                        }
                    } label: {
                        Image(systemName: "face.smiling.fill")
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        showGIFPicker = true
                    } label: {
                        Text("GIF")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .frame(width: 42, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.blue.opacity(0.18))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.blue.opacity(0.32), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    
                    TextField("Message the community...", text: $draftMessage, axis: .vertical)
                        .lineLimit(1...2)
                        .focused($isChatInputFocused)
                        .submitLabel(.send)
                        .onSubmit {
                            Task { await sendMessage() }
                        }
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                    
                    
                    Button {
                        Task { await sendMessage() }
                    } label: {
                        Group {
                            if sendingMessage {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 16, weight: .bold))
                            }
                        }
                        .foregroundColor(.black)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(sendingMessage)
                }
                .padding(.horizontal, 12)
                
                HStack(spacing: 8) {
                    Button {
                        if let replyTarget = selectedReplyTarget {
                            let mention = "@\(replyTarget.senderName.replacingOccurrences(of: " ", with: ""))"
                            if !draftMessage.contains(mention) {
                                draftMessage = draftMessage.isEmpty ? "\(mention) " : "\(draftMessage) \(mention) "
                            }
                        } else {
                            showToast("Tap a message first to reply.")
                        }
                    } label: {
                        chatToolChip(icon: "arrowshape.turn.up.left.fill", label: "Reply")
                    }
                    .buttonStyle(.plain)
                    
                    Menu {
                        ForEach(members.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { member in
                            Button("@\(member.name)") {
                                let mention = "@\(member.name.replacingOccurrences(of: " ", with: ""))"
                                draftMessage = draftMessage.isEmpty ? "\(mention) " : "\(draftMessage) \(mention) "
                            }
                        }
                    } label: {
                        chatToolChip(icon: "at", label: "Mention")
                    }
                    .buttonStyle(.plain)
                    
                    Menu {
                        ForEach(quickComposerEmojis, id: \.self) { emoji in
                            Button(emoji) {
                                draftMessage += draftMessage.isEmpty ? emoji : " \(emoji)"
                            }
                        }
                    } label: {
                        chatToolChip(icon: "sparkles", label: "React")
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(glassCard)
        .overlay(glowStroke)
    }
    
    private let quickComposerEmojis = ["😀", "🔥", "👏", "🎉", "✅", "❤️", "😂", "🙌"]
    
    private var suggestedGIFs: [SuggestedGIF] {
        [
            SuggestedGIF(title: "Celebration", urlString: "https://media.giphy.com/media/111ebonMs90YLu/giphy.gif"),
            SuggestedGIF(title: "Applause", urlString: "https://media.giphy.com/media/l3q2XhfQ8oCkm1Ts4/giphy.gif"),
            SuggestedGIF(title: "Laugh", urlString: "https://media.giphy.com/media/10JhviFuU2gWD6/giphy.gif"),
            SuggestedGIF(title: "Fire", urlString: "https://media.giphy.com/media/3o72FfM5HJydzafgUE/giphy.gif"),
            SuggestedGIF(title: "Approved", urlString: "https://media.giphy.com/media/26u4cqiYI30juCOGY/giphy.gif"),
            SuggestedGIF(title: "Wow", urlString: "https://media.giphy.com/media/5VKbvrjxpVJCM/giphy.gif"),
            SuggestedGIF(title: "Victory", urlString: "https://media.giphy.com/media/3ohzdIuqJoo8QdKlnW/giphy.gif"),
            SuggestedGIF(title: "Dance", urlString: "https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif")
        ]
    }
    
    private func previewText(for message: CommunityMessage) -> String {
        if let gifURL = message.gifURL, !gifURL.isEmpty {
            return "GIF message"
        }
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Message" : trimmed
    }
    
    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastText = text
        }
        
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if toastText == text {
                        toastText = nil
                    }
                }
            }
        }
    }
    
    // MARK: Contribute Panel
    
    private var contributePanel: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Contribute to Fund")
                    .font(.headline)
                    .foregroundColor(.white)
                
                HStack(spacing: 10) {
                    TextField("Amount", text: $contributionInput)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                    
                    Text(currencyCode.uppercased())
                        .font(.subheadline.bold())
                        .foregroundColor(.gray)
                        .padding(.horizontal, 10)
                }
                
                TextField("Reason / note (optional)", text: $contributionReason)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                
                Button {
                    Task { await submitContribution() }
                } label: {
                    HStack {
                        Spacer()
                        if contributionBusy {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Text("Record Contribution")
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .foregroundColor(.black)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white)
                    )
                }
                .buttonStyle(.plain)
                .disabled(contributionBusy)
            }
            .padding(14)
            .background(glassCard)
            .overlay(glowStroke)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Fund Contributions")
                    .font(.headline)
                    .foregroundColor(.white)
                
                if contributions.isEmpty {
                    Text("No contributions yet.")
                        .foregroundColor(.gray)
                        .padding(.top, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(contributions) { row in
                                ContributionRowView(row: row)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(14)
            .background(glassCard)
            .overlay(glowStroke)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Withdrawals")
                    .font(.headline)
                    .foregroundColor(.white)
                
                if withdrawals.isEmpty {
                    Text("No withdrawals yet.")
                        .foregroundColor(.gray)
                        .padding(.top, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(withdrawals) { row in
                                WithdrawalRowView(row: row)
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }
            .padding(14)
            .background(glassCard)
            .overlay(glowStroke)
        }
    }
    
    // MARK: Vote/Governance Panel
    
    private var votePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Governance")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("Ledger + Disputes")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            if governanceEvents.isEmpty {
                Text("No governance events yet.")
                    .foregroundColor(.gray)
                    .padding(.top, 6)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(governanceEvents) { event in
                            GovernanceEventRowView(row: event)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(glassCard)
        .overlay(glowStroke)
    }
    
    // MARK: Members Panel
    
    private var membersPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Members")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Text("\(members.count)")
                    .font(.caption.bold())
                    .foregroundColor(.gray)
            }
            
            if members.isEmpty {
                Text("No members found.")
                    .foregroundColor(.gray)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(members) { member in
                            MemberRowView(member: member)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(glassCard)
        .overlay(glowStroke)
    }
    
    // MARK: Styling
    
    private var glassCard: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(0.06),
                Color.white.opacity(0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var glowStroke: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.15),
                        Color.blue.opacity(0.10),
                        Color.white.opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
    
    // MARK: Data Loading
    
    @MainActor
    private func loadTerminalData() async {
        loading = true
        errorText = nil
        
        guard let uid = Auth.auth().currentUser?.uid else {
            loading = false
            errorText = "You’re not signed in."
            return
        }
        
        do {
            let db = Firestore.firestore()
            
            let gSnap = try await db.collection("njangiGroups").document(groupId).getDocument()
            guard gSnap.exists else {
                loading = false
                errorText = "Community not found."
                return
            }
            
            let d = gSnap.data() ?? [:]
            
            groupName = (d["name"] as? String)
            ?? (d["clubTitle"] as? String)
            ?? groupTitle
            
            crestPath = d["crestPath"] as? String
            
            contributionPerRound = {
                if let n = d["contributionPerRound"] as? Double { return n }
                if let n = d["contributionPerRound"] as? Int { return Double(n) }
                if let n = d["contributionPerRound"] as? NSNumber { return n.doubleValue }
                if let s = d["contributionPerRound"] as? String, let v = Double(s) { return v }
                return nil
            }()
            
            currencyCode = (d["currency"] as? String)
            ?? (d["contributionCurrency"] as? String)
            ?? "USD"
            
            let status = (d["status"] as? String) ?? ""
            statusText = status.isEmpty ? "" : "Status: \(status)"
            
            if let crestPath, !crestPath.isEmpty {
                do {
                    let ref = Storage.storage().reference(withPath: crestPath)
                    crestURL = try await ref.downloadURL()
                } catch {
                    crestURL = nil
                }
            }
            
            currentUserName = await loadCurrentUserName(uid: uid)
            currentUserEmail = Auth.auth().currentUser?.email ?? ""
            
            guard await userCanAccessCommunity(groupData: d, uid: uid) else {
                removeListeners()
                members = []
                messages = []
                contributions = []
                withdrawals = []
                governanceEvents = []
                loading = false
                errorText = "You can only view communities you already belong to."
                return
            }
            
            startMessagesListener()
            startMembersListener()
            startContributionsListener()
            startWithdrawalsListener()
            startGovernanceListeners()
            
            Task { await markCommunityAsRead() }
            
            loading = false
        } catch {
            loading = false
            errorText = error.localizedDescription
        }
    }
    
    @MainActor
    private func startMessagesListener() {
        messageListener?.remove()

        let db = Firestore.firestore()
        messageListener = db.collection("njangiGroups")
            .document(groupId)
            .collection("communityMessages")
            .order(by: "createdAt", descending: false)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[NjangiCommunityTerminalView] message listener error: \(error.localizedDescription)")
                    return
                }

                let docs = snapshot?.documents ?? []
                let currentUid = Auth.auth().currentUser?.uid ?? ""

                let baseMessages: [CommunityMessage] = docs.map { doc in
                    let d = doc.data()
                    let reactions = normalizedReactions(from: d["reactions"])
                    let reactionCounts = Dictionary(
                        uniqueKeysWithValues: reactions.map { key, uids in (key, uids.count) }
                    )
                    let myReactionKeys = Set(
                        reactions.compactMap { key, uids in
                            uids.contains(currentUid) ? key : nil
                        }
                    )

                    return CommunityMessage(
                        id: doc.documentID,
                        text: d["text"] as? String ?? "",
                        gifURL: firstNonEmptyString(d["gifURL"], d["mediaURL"], d["attachmentURL"]),
                        senderUid: d["senderUid"] as? String ?? "",
                        senderName: d["senderName"] as? String ?? "Member",
                        senderPhotoURL: firstNonEmptyString(
                            d["senderPhotoURL"],
                            d["photoURL"],
                            d["profileImageURL"],
                            d["profilePhotoURL"],
                            d["avatarURL"]
                        ),
                        senderPhotoPath: firstNonEmptyString(
                            d["senderPhotoPath"],
                            d["photoPath"],
                            d["profileImagePath"],
                            d["profilePhotoPath"],
                            d["avatarPath"],
                            d["imagePath"]
                        ),
                        replyToMessageId: d["replyToMessageId"] as? String,
                        replyToSenderName: d["replyToSenderName"] as? String,
                        replyPreview: d["replyPreview"] as? String,
                        reactionCounts: reactionCounts,
                        myReactionKeys: myReactionKeys,
                        createdAt: d["createdAt"] as? Timestamp
                    )
                }

                Task {
                    let enriched = await enrichMessagesFromUsers(baseMessages)
                    await MainActor.run {
                        self.messages = enriched
                    }

                    if self.selectedSection == .chat {
                        await markCommunityAsRead()
                    }
                }
            }
    }
    
    @MainActor
    private func startMembersListener() {
        membersListener?.remove()

        let db = Firestore.firestore()
        membersListener = db.collection("njangiGroups")
            .document(groupId)
            .collection("members")
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[NjangiCommunityTerminalView] members listener error: \(error.localizedDescription)")
                }

                let docs = snapshot?.documents ?? []
                let baseMembers: [CommunityMember] = docs.map { doc in
                    self.communityMember(from: doc.data(), fallbackId: doc.documentID)
                }

                Task {
                    let merged = await self.mergeMembersWithGroupFallback(baseMembers)
                    let enriched = await self.enrichMembersFromUsers(merged)
                    await MainActor.run {
                        self.members = enriched
                    }
                }
            }
    }
    
    @MainActor
    private func startContributionsListener() {
        contributionsListener?.remove()

        let db = Firestore.firestore()
        contributionsListener = db.collection("njangiGroups")
            .document(groupId)
            .collection("fundsContributions")
            .addSnapshotListener { snapshot, error in
                if error != nil { return }
                guard let docs = snapshot?.documents else { return }

                let rows = docs.map { doc -> FundContribution in
                    let d = doc.data()
                    return FundContribution(
                        id: doc.documentID,
                        amount: numericValue(d["amount"]),
                        currency: (d["currency"] as? String) ?? self.currencyCode,
                        reason: (d["reason"] as? String) ?? "",
                        contributorUid: (d["contributorUid"] as? String) ?? "",
                        contributorName: (d["contributorName"] as? String) ?? "",
                        contributorEmail: (d["contributorEmail"] as? String) ?? "",
                        createdAt: d["createdAt"] as? Timestamp
                    )
                }

                self.contributions = rows.sorted {
                    toMillis($0.createdAt) > toMillis($1.createdAt)
                }
            }
    }

    @MainActor
    private func startWithdrawalsListener() {
        withdrawalsListener?.remove()

        let db = Firestore.firestore()
        withdrawalsListener = db.collection("njangiClubWithdrawals")
            .whereField("groupId", isEqualTo: groupId)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .addSnapshotListener { snapshot, error in
                if error != nil { return }
                guard let docs = snapshot?.documents else { return }

                self.withdrawals = docs.map { doc in
                    let d = doc.data()
                    return WithdrawalRecord(
                        id: doc.documentID,
                        amount: numericValue(d["amount"]),
                        currency: (d["currency"] as? String) ?? self.currencyCode,
                        feeAmount: numericValue(d["feeAmount"]),
                        netAmount: numericValue(d["netAmount"]),
                        status: (d["status"] as? String) ?? "requested",
                        reason: (d["reason"] as? String)
                            ?? (d["blockReason"] as? String)
                            ?? (d["blockMessage"] as? String)
                            ?? "",
                        withdrawToUid: (d["withdrawToUid"] as? String) ?? "",
                        approvedByUid: (d["approvedByUid"] as? String) ?? "",
                        createdAt: d["createdAt"] as? Timestamp
                    )
                }
            }
    }
                    @MainActor
                    private func startGovernanceListeners() {
                        ledgerListener?.remove()
                        disputesListener?.remove()
                        governanceLedgerRaw = []
                        governanceDisputesRaw = []
                        
                        let db = Firestore.firestore()
                        
                        ledgerListener = db.collection("njangiGroups")
                            .document(groupId)
                            .collection("ledger")
                            .order(by: "ts", descending: true)
                            .limit(to: 80)
                            .addSnapshotListener { snapshot, error in
                                if error != nil { return }
                                self.governanceLedgerRaw = snapshot?.documents.map { doc in
                                    var d = doc.data()
                                    d["__id"] = doc.documentID
                                    return d
                                } ?? []
                                self.rebuildGovernanceEvents()
                            }
                        
                        disputesListener = db.collection("njangiGroups")
                            .document(groupId)
                            .collection("disputes")
                            .order(by: "createdAt", descending: true)
                            .limit(to: 80)
                            .addSnapshotListener { snapshot, error in
                                if error != nil { return }
                                self.governanceDisputesRaw = snapshot?.documents.map { doc in
                                    var d = doc.data()
                                    d["__id"] = doc.documentID
                                    return d
                                } ?? []
                                self.rebuildGovernanceEvents()
                            }
                    }
                    
                    @MainActor
                    private func rebuildGovernanceEvents() {
                        var rows: [GovernanceEvent] = []
                        
                        for d in governanceLedgerRaw {
                            let id = (d["__id"] as? String) ?? UUID().uuidString
                            let ts = (d["ts"] as? Timestamp) ?? (d["createdAt"] as? Timestamp) ?? (d["updatedAt"] as? Timestamp)
                            
                            rows.append(
                                GovernanceEvent(
                                    id: "ledger_\(id)",
                                    kind: "ledger",
                                    title: ledgerLabel(for: d),
                                    detail: ledgerDetail(for: d),
                                    status: nil,
                                    timestamp: ts?.dateValue()
                                )
                            )
                        }
                        
                        for d in governanceDisputesRaw {
                            let id = (d["__id"] as? String) ?? UUID().uuidString
                            let title = (d["title"] as? String)
                            ?? (d["reason"] as? String)
                            ?? "Dispute"
                            
                            let openedBy = (d["openedByName"] as? String)
                            ?? (d["openedByEmail"] as? String)
                            ?? (d["openedByUid"] as? String)
                            ?? (d["createdByName"] as? String)
                            ?? (d["createdByUid"] as? String)
                            ?? ""
                            
                            let payoutIntent = (d["payoutIntentId"] as? String) ?? ""
                            let resolution = (d["resolutionNote"] as? String)
                            ?? (d["resolution"] as? String)
                            ?? ""
                            
                            var detailParts: [String] = []
                            if !openedBy.isEmpty { detailParts.append("Opened by \(openedBy)") }
                            if !payoutIntent.isEmpty { detailParts.append("Payout \(shortUid(payoutIntent))") }
                            if !resolution.isEmpty { detailParts.append("Resolution: \(resolution)") }
                            
                            let ts = (d["createdAt"] as? Timestamp) ?? (d["ts"] as? Timestamp)
                            
                            rows.append(
                                GovernanceEvent(
                                    id: "dispute_\(id)",
                                    kind: "dispute",
                                    title: title,
                                    detail: detailParts.joined(separator: " • "),
                                    status: (d["status"] as? String) ?? "open",
                                    timestamp: ts?.dateValue()
                                )
                            )
                        }
                        
                        governanceEvents = rows.sorted {
                            ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
                        }
                    }
                    
                    private func loadCurrentUserName(uid: String) async -> String {
                        let authName = Auth.auth().currentUser?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let authName, !authName.isEmpty {
                            return authName
                        }
                        
                        do {
                            let fsDoc = try await Firestore.firestore().collection("users").document(uid).getDocument()
                            if let d = fsDoc.data() {
                                if let name = d["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    return name
                                }
                                if let username = d["username"] as? String, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    return username
                                }
                                if let displayName = d["displayName"] as? String, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    return displayName
                                }
                            }
                        } catch { }
                        
                        return "Member"
                    }
                    
                    private func nonEmpty(_ value: String?) -> String? {
                        guard let value else { return nil }
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    
                    private func firstNonEmptyString(_ values: Any?...) -> String? {
                        for value in values {
                            if let s = value as? String,
                               let trimmed = nonEmpty(s) {
                                return trimmed
                            }
                        }
                        return nil
                    }
                    
                    private func resolveUserProfile(uid: String) async -> (name: String?, photoURL: String?, photoPath: String?) {
                        let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedUID.isEmpty else { return (nil, nil, nil) }
                        
                        do {
                            let snap = try await Firestore.firestore().collection("users").document(trimmedUID).getDocument()
                            let data = snap.data() ?? [:]
                            
                            let name = firstNonEmptyString(
                                data["name"],
                                data["displayName"],
                                data["username"],
                                data["fullName"],
                                data["senderName"],
                                data["ownerName"],
                                data["email"]
                            )
                            
                            let photoURL = firstNonEmptyString(
                                data["profileImageURL"],
                                data["profilePhotoURL"],
                                data["photoURL"],
                                data["avatarURL"],
                                data["imageURL"],
                                data["profilePicURL"]
                            ) ?? Auth.auth().currentUser?.photoURL?.absoluteString
                            
                            let photoPath = firstNonEmptyString(
                                data["profileImagePath"],
                                data["profilePhotoPath"],
                                data["photoPath"],
                                data["avatarPath"],
                                data["imagePath"],
                                data["profilePicPath"]
                            )
                            
                            return (name, photoURL, photoPath)
                        } catch {
                            return (
                                Auth.auth().currentUser?.displayName,
                                Auth.auth().currentUser?.photoURL?.absoluteString,
                                nil
                            )
                        }
                    }
                    
                    private func normalizedReactions(from raw: Any?) -> [String: [String]] {
                        guard let dict = raw as? [String: Any] else { return [:] }
                        var result: [String: [String]] = [:]
                        
                        for (key, value) in dict {
                            if let values = value as? [String] {
                                result[key] = values
                            } else if let values = value as? [Any] {
                                result[key] = values.compactMap { $0 as? String }
                            }
                        }
                        
                        return result
                    }
                    
                    private func reactionEmoji(for key: String) -> String {
                        switch key {
                        case "fire": return "🔥"
                        case "clap": return "👏"
                        case "joy": return "😂"
                        case "heart": return "❤️"
                        default: return "✨"
                        }
                    }
                    
                    private func replyPreviewText(text: String, gifURL: String?) -> String {
                        if let gifURL, !gifURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return "GIF"
                        }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "Message" : String(trimmed.prefix(80))
                    }
                    
                    private func toggleReaction(for message: CommunityMessage, key: String) async {
                        guard let uid = Auth.auth().currentUser?.uid else { return }
                        
                        let ref = Firestore.firestore()
                            .collection("njangiGroups")
                            .document(groupId)
                            .collection("communityMessages")
                            .document(message.id)
                        
                        do {
                            _ = try await Firestore.firestore().runTransaction { transaction, errorPointer in
                                let snapshot: DocumentSnapshot
                                
                                do {
                                    snapshot = try transaction.getDocument(ref)
                                } catch let fetchError as NSError {
                                    errorPointer?.pointee = fetchError
                                    return nil
                                }
                                
                                let data = snapshot.data() ?? [:]
                                var reactions = normalizedReactions(from: data["reactions"])
                                var bucket = reactions[key] ?? []
                                
                                if bucket.contains(uid) {
                                    bucket.removeAll { $0 == uid }
                                } else {
                                    bucket.append(uid)
                                }
                                
                                reactions[key] = bucket
                                transaction.setData(["reactions": reactions], forDocument: ref, merge: true)
                                return nil
                            }
                        } catch {
                            await MainActor.run {
                                showToast("Could not update reaction.")
                            }
                        }
                    }
                    
                    private func communityMember(from data: [String: Any], fallbackId: String) -> CommunityMember {
                        let uid = ((data["uid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? ((data["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? fallbackId
                        
                        let rawName = (data["displayName"] as? String)
                        ?? (data["name"] as? String)
                        ?? (data["senderName"] as? String)
                        ?? (data["ownerName"] as? String)
                        ?? (data["email"] as? String)
                        ?? "Member"
                        
                        return CommunityMember(
                            id: uid,
                            uid: uid,
                            name: rawName,
                            role: (data["role"] as? String) ?? "member",
                            photoURL: (data["photoURL"] as? String)
                            ?? (data["profileImageURL"] as? String)
                            ?? (data["profilePhotoURL"] as? String)
                            ?? (data["avatarURL"] as? String),
                            photoPath: (data["photoPath"] as? String)
                            ?? (data["profileImagePath"] as? String)
                            ?? (data["profilePhotoPath"] as? String)
                            ?? (data["avatarPath"] as? String),
                            joinedAt: data["joinedAt"] as? Timestamp
                        )
                    }
                    
                    private func normalizeRole(_ role: String) -> String {
                        let normalized = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        switch normalized {
                        case "owner": return "owner"
                        case "admin": return "admin"
                        case "member": return "member"
                        default: return normalized.isEmpty ? "member" : normalized
                        }
                    }
                    
                    private func roleRank(_ role: String) -> Int {
                        switch normalizeRole(role) {
                        case "owner": return 0
                        case "admin": return 1
                        case "member": return 2
                        default: return 3
                        }
                    }
                    
                    private func mergedMember(_ incoming: CommunityMember, over existing: CommunityMember?) -> CommunityMember {
                        guard let existing else {
                            return CommunityMember(
                                id: incoming.uid,
                                uid: incoming.uid,
                                name: incoming.name,
                                role: normalizeRole(incoming.role),
                                photoURL: incoming.photoURL,
                                photoPath: incoming.photoPath,
                                joinedAt: incoming.joinedAt
                            )
                        }
                        
                        let chosenRole = roleRank(incoming.role) < roleRank(existing.role) ? normalizeRole(incoming.role) : normalizeRole(existing.role)
                        let chosenName = !incoming.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && incoming.name != "Member"
                        ? incoming.name
                        : existing.name
                        
                        return CommunityMember(
                            id: existing.uid,
                            uid: existing.uid,
                            name: chosenName,
                            role: chosenRole,
                            photoURL: incoming.photoURL ?? existing.photoURL,
                            photoPath: incoming.photoPath ?? existing.photoPath,
                            joinedAt: incoming.joinedAt ?? existing.joinedAt
                        )
                    }
                    
                    private func ownerFallbackMember(uid ownerId: String, groupData: [String: Any]) -> CommunityMember {
                        CommunityMember(
                            id: ownerId,
                            uid: ownerId,
                            name: (groupData["ownerName"] as? String)
                            ?? (groupData["displayName"] as? String)
                            ?? (groupData["name"] as? String)
                            ?? (groupData["ownerEmail"] as? String)
                            ?? "Member",
                            role: "owner",
                            photoURL: (groupData["ownerPhotoURL"] as? String)
                            ?? (groupData["photoURL"] as? String)
                            ?? (groupData["profileImageURL"] as? String),
                            photoPath: (groupData["ownerPhotoPath"] as? String)
                            ?? (groupData["photoPath"] as? String)
                            ?? (groupData["profileImagePath"] as? String),
                            joinedAt: groupData["createdAt"] as? Timestamp
                        )
                    }
                    
                    private func mergeMembersWithGroupFallback(_ baseMembers: [CommunityMember]) async -> [CommunityMember] {
                        let db = Firestore.firestore()
                        var byUID: [String: CommunityMember] = [:]
                        
                        for member in baseMembers {
                            byUID[member.uid] = mergedMember(member, over: byUID[member.uid])
                        }
                        
                        do {
                            let groupSnap = try await db.collection("njangiGroups").document(groupId).getDocument()
                            let groupData = groupSnap.data() ?? [:]
                            
                            if let ownerId = (groupData["ownerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ownerId.isEmpty {
                                let owner = ownerFallbackMember(uid: ownerId, groupData: groupData)
                                byUID[ownerId] = mergedMember(owner, over: byUID[ownerId])
                                byUID[ownerId] = CommunityMember(
                                    id: ownerId,
                                    uid: ownerId,
                                    name: byUID[ownerId]?.name ?? owner.name,
                                    role: "owner",
                                    photoURL: byUID[ownerId]?.photoURL ?? owner.photoURL,
                                    photoPath: byUID[ownerId]?.photoPath ?? owner.photoPath,
                                    joinedAt: byUID[ownerId]?.joinedAt ?? owner.joinedAt
                                )
                            }
                            
                            if let membersMap = groupData["members"] as? [String: Any] {
                                for (uid, rawEntry) in membersMap {
                                    guard let entry = rawEntry as? [String: Any] else { continue }
                                    let denorm = communityMember(from: entry, fallbackId: uid)
                                    byUID[uid] = mergedMember(denorm, over: byUID[uid])
                                }
                            }
                        } catch {
                            print("[NjangiCommunityTerminalView] mergeMembersWithGroupFallback failed: \(error.localizedDescription)")
                        }
                        
                        return byUID.values.sorted {
                            let leftRank = roleRank($0.role)
                            let rightRank = roleRank($1.role)
                            if leftRank != rightRank { return leftRank < rightRank }
                            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        }
                    }
                    
                    private func userCanAccessCommunity(groupData: [String: Any], uid: String) async -> Bool {
                        let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedUID.isEmpty else { return false }
                        
                        if (groupData["ownerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedUID {
                            return true
                        }
                        
                        if let membersMap = groupData["members"] as? [String: Any], membersMap[trimmedUID] != nil {
                            return true
                        }
                        
                        let db = Firestore.firestore()
                        
                        do {
                            let memberDoc = try await db.collection("njangiGroups")
                                .document(groupId)
                                .collection("members")
                                .document(trimmedUID)
                                .getDocument()
                            if memberDoc.exists { return true }
                        } catch { }
                        
                        do {
                            let reverseDoc = try await db.collection("njangiMemberships")
                                .document(trimmedUID)
                                .collection("groups")
                                .document(groupId)
                                .getDocument()
                            if reverseDoc.exists { return true }
                        } catch { }
                        
                        do {
                            let cg = try await db.collectionGroup("members")
                                .whereField("uid", isEqualTo: trimmedUID)
                                .getDocuments()
                            if cg.documents.contains(where: { $0.reference.parent.parent?.documentID == groupId }) {
                                return true
                            }
                        } catch { }
                        
                        return false
                    }
                    
                    private func enrichMembersFromUsers(_ baseMembers: [CommunityMember]) async -> [CommunityMember] {
                        let db = Firestore.firestore()
                        var cache: [String: (name: String?, photoURL: String?, photoPath: String?)] = [:]
                        var enriched: [CommunityMember] = []
                        enriched.reserveCapacity(baseMembers.count)
                        
                        for member in baseMembers {
                            let hasGoodName = !member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && member.name != "Member"
                            let hasPhotoURL = !(member.photoURL ?? "").isEmpty
                            let hasPhotoPath = !(member.photoPath ?? "").isEmpty
                            
                            if hasGoodName && (hasPhotoURL || hasPhotoPath) {
                                enriched.append(member)
                                continue
                            }
                            
                            if let cached = cache[member.uid] {
                                let resolvedName = (cached.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                                ? (cached.name ?? member.name)
                                : member.name
                                
                                enriched.append(
                                    CommunityMember(
                                        id: member.id,
                                        uid: member.uid,
                                        name: resolvedName,
                                        role: member.role,
                                        photoURL: cached.photoURL ?? member.photoURL,
                                        photoPath: cached.photoPath ?? member.photoPath,
                                        joinedAt: member.joinedAt
                                    )
                                )
                                continue
                            }
                            
                            do {
                                let userSnap = try await db.collection("users").document(member.uid).getDocument()
                                if let d = userSnap.data() {
                                    let resolvedName = (d["name"] as? String)
                                    ?? (d["displayName"] as? String)
                                    ?? (d["username"] as? String)
                                    ?? member.name
                                    
                                    let resolvedPhoto = (d["profileImageURL"] as? String)
                                    ?? (d["photoURL"] as? String)
                                    ?? member.photoURL
                                    
                                    let resolvedPhotoPath = (d["profileImagePath"] as? String)
                                    ?? (d["photoPath"] as? String)
                                    ?? (d["avatarPath"] as? String)
                                    ?? member.photoPath
                                    
                                    cache[member.uid] = (resolvedName, resolvedPhoto, resolvedPhotoPath)
                                    
                                    enriched.append(
                                        CommunityMember(
                                            id: member.id,
                                            uid: member.uid,
                                            name: resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? member.name : resolvedName,
                                            role: member.role,
                                            photoURL: resolvedPhoto,
                                            photoPath: resolvedPhotoPath,
                                            joinedAt: member.joinedAt
                                        )
                                    )
                                } else {
                                    enriched.append(member)
                                }
                            } catch {
                                enriched.append(member)
                            }
                        }
                        
                        return enriched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    }
                    
                    private func enrichMessagesFromUsers(_ baseMessages: [CommunityMessage]) async -> [CommunityMessage] {
                        var cache: [String: (name: String?, photoURL: String?, photoPath: String?)] = [:]
                        var enriched: [CommunityMessage] = []
                        enriched.reserveCapacity(baseMessages.count)
                        
                        for message in baseMessages {
                            let uid = message.senderUid.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !uid.isEmpty else {
                                enriched.append(message)
                                continue
                            }
                            
                            if let cached = cache[uid] {
                                enriched.append(
                                    CommunityMessage(
                                        id: message.id,
                                        text: message.text,
                                        gifURL: message.gifURL,
                                        senderUid: message.senderUid,
                                        senderName: nonEmpty(cached.name) ?? message.senderName,
                                        senderPhotoURL: nonEmpty(cached.photoURL) ?? message.senderPhotoURL,
                                        senderPhotoPath: nonEmpty(cached.photoPath) ?? message.senderPhotoPath,
                                        replyToMessageId: message.replyToMessageId,
                                        replyToSenderName: message.replyToSenderName,
                                        replyPreview: message.replyPreview,
                                        reactionCounts: message.reactionCounts,
                                        myReactionKeys: message.myReactionKeys,
                                        createdAt: message.createdAt
                                    )
                                )
                                continue
                            }
                            
                            let profile = await resolveUserProfile(uid: uid)
                            cache[uid] = profile
                            
                            enriched.append(
                                CommunityMessage(
                                    id: message.id,
                                    text: message.text,
                                    gifURL: message.gifURL,
                                    senderUid: message.senderUid,
                                    senderName: nonEmpty(profile.name) ?? message.senderName,
                                    senderPhotoURL: nonEmpty(profile.photoURL) ?? message.senderPhotoURL,
                                    senderPhotoPath: nonEmpty(profile.photoPath) ?? message.senderPhotoPath,
                                    replyToMessageId: message.replyToMessageId,
                                    replyToSenderName: message.replyToSenderName,
                                    replyPreview: message.replyPreview,
                                    reactionCounts: message.reactionCounts,
                                    myReactionKeys: message.myReactionKeys,
                                    createdAt: message.createdAt
                                )
                            )
                        }
                        
                        return enriched
                    }
                    
                    private func sendMessage() async {
                        guard let uid = Auth.auth().currentUser?.uid else { return }
                        
                        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        guard !sendingMessage else { return }
                        
                        sendingMessage = true
                        defer { sendingMessage = false }
                        
                        let profile = await resolveUserProfile(uid: uid)
                        let replyTarget = selectedReplyTarget
                        
                        do {
                            try await Firestore.firestore()
                                .collection("njangiGroups")
                                .document(groupId)
                                .collection("communityMessages")
                                .addDocument(data: [
                                    "text": text,
                                    "gifURL": "",
                                    "senderUid": uid,
                                    "senderName": nonEmpty(profile.name) ?? currentUserName,
                                    "senderPhotoURL": nonEmpty(profile.photoURL) ?? "",
                                    "senderPhotoPath": nonEmpty(profile.photoPath) ?? "",
                                    "groupId": groupId,
                                    "groupTitle": groupName.isEmpty ? groupTitle : groupName,
                                    "messageType": "text",
                                    "previewText": text,
                                    "createdAt": FieldValue.serverTimestamp()
                                ])
                            
                            
                            await MainActor.run {
                                draftMessage = ""
                                selectedReplyTarget = nil
                            }
                        } catch {
                            await MainActor.run {
                                showToast("Failed to send message.")
                            }
                        }
                    }
                    
                    private func sendGIFMessage(urlString: String) async {
                        guard let uid = Auth.auth().currentUser?.uid else { return }
                        
                        let gifURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !gifURL.isEmpty, URL(string: gifURL) != nil else {
                            await MainActor.run {
                                showToast("Unable to use that GIF.")
                            }
                            return
                        }
                        
                        let profile = await resolveUserProfile(uid: uid)
                        let replyTarget = selectedReplyTarget
                        
                        do {
                            try await Firestore.firestore()
                                .collection("njangiGroups")
                                .document(groupId)
                                .collection("communityMessages")
                                .addDocument(data: [
                                    "text": "",
                                    "gifURL": gifURL,
                                    "senderUid": uid,
                                    "senderName": nonEmpty(profile.name) ?? currentUserName,
                                    "senderPhotoURL": nonEmpty(profile.photoURL) ?? "",
                                    "senderPhotoPath": nonEmpty(profile.photoPath) ?? "",
                                    "groupId": groupId,
                                    "groupTitle": groupName.isEmpty ? groupTitle : groupName,
                                    "messageType": "gif",
                                    "previewText": "sent a GIF",
                                    "createdAt": FieldValue.serverTimestamp()
                                ])
                            
                            
                            await MainActor.run {
                                selectedReplyTarget = nil
                                showGIFPicker = false
                            }
                        } catch {
                            await MainActor.run {
                                showToast("Failed to send GIF.")
                            }
                        }
                    }
                    
                    private func markCommunityAsRead() async {
                        guard let uid = Auth.auth().currentUser?.uid else { return }
                        
                        let now = Timestamp(date: Date())
                        let db = Firestore.firestore()
                        
                        do {
                            try await db.collection("njangiGroups")
                                .document(groupId)
                                .collection("members")
                                .document(uid)
                                .setData([
                                    "lastReadCommunityMessageAt": now,
                                    "unreadCommunityCount": 0
                                ], merge: true)
                            
                            try await db.collection("users")
                                .document(uid)
                                .collection("communityInbox")
                                .document(groupId)
                                .setData([
                                    "groupId": groupId,
                                    "groupTitle": groupName.isEmpty ? groupTitle : groupName,
                                    "lastReadAt": now,
                                    "unreadCount": 0,
                                    "updatedAt": FieldValue.serverTimestamp()
                                ], merge: true)
                        } catch {
                            print("Failed to mark community as read: \(error.localizedDescription)")
                        }
                    }
                    
                    private func submitContribution() async {
                        guard let uid = Auth.auth().currentUser?.uid else { return }
                        
                        let rawAmount = contributionInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let amount = Double(rawAmount), amount > 0 else {
                            errorText = "Enter a valid contribution amount."
                            return
                        }
                        
                        contributionBusy = true
                        defer { contributionBusy = false }
                        
                        do {
                            try await Firestore.firestore()
                                .collection("njangiGroups")
                                .document(groupId)
                                .collection("fundsContributions")
                                .addDocument(data: [
                                    "groupId": groupId,
                                    "amount": amount,
                                    "currency": currencyCode,
                                    "reason": contributionReason.trimmingCharacters(in: .whitespacesAndNewlines),
                                    "contributorUid": uid,
                                    "contributorName": currentUserName,
                                    "contributorEmail": currentUserEmail,
                                    "createdAt": FieldValue.serverTimestamp()
                                ])
                            
                            await MainActor.run {
                                contributionInput = ""
                                contributionReason = ""
                            }
                        } catch {
                            await MainActor.run {
                                errorText = "Failed to record contribution: \(error.localizedDescription)"
                            }
                        }
                    }
                    
                    private func makeInviteCode() -> String {
                        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        return String(raw.prefix(12)).uppercased()
                    }
                    
                    private func inviteExpiryDate() -> Date {
                        Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date().addingTimeInterval(7 * 24 * 60 * 60)
                    }
                    
                    private func buildInviteURL(inviteCode: String) -> URL {
                        var c = URLComponents()
                        c.scheme = "https"
                        c.host = "black-app-web.web.app"
                        c.path = "/njangi"
                        c.queryItems = [
                            URLQueryItem(name: "groupId", value: groupId),
                            URLQueryItem(name: "screen", value: "community"),
                            URLQueryItem(name: "inviteCode", value: inviteCode)
                        ]
                        return c.url ?? URL(string: "https://black-app-web.web.app/njangi?groupId=\(groupId)&screen=community&inviteCode=\(inviteCode)")!
                    }
                    
                    private func createInviteRecord() async throws -> URL {
                        guard let inviterUid = Auth.auth().currentUser?.uid else {
                            throw NSError(domain: "NjangiInvite", code: 401, userInfo: [NSLocalizedDescriptionKey: "You must be signed in to create an invite."])
                        }
                        
                        let code = makeInviteCode()
                        let expiresAt = inviteExpiryDate()
                        let title = groupName.isEmpty ? groupTitle : groupName
                        
                        let payload: [String: Any] = [
                            "code": code,
                            "groupId": groupId,
                            "groupTitle": title,
                            "invitedByUid": inviterUid,
                            "invitedByName": currentUserName,
                            "createdAt": FieldValue.serverTimestamp(),
                            "expiresAt": Timestamp(date: expiresAt),
                            "status": "active",
                            "type": "membership"
                        ]
                        
                        let db = Firestore.firestore()
                        try await db.collection("njangiGroups").document(groupId).collection("invites").document(code).setData(payload)
                        try await db.collection("njangiInviteCodes").document(code).setData(payload)
                        return buildInviteURL(inviteCode: code)
                    }
                    
                    private func prepareInviteLinkForSharing() async {
                        guard !inviteBusy else { return }
                        inviteBusy = true
                        defer { inviteBusy = false }
                        
                        do {
                            let inviteURL = try await createInviteRecord()
                            let title = groupName.isEmpty ? groupTitle : groupName
                            let text = """
            Join \(title) on BlackApp Community. This membership is by invitation only.
            
            \(inviteURL.absoluteString)
            """
                            
                            await MainActor.run {
                                shareInviteItems = [text, inviteURL]
                                showShareSheet = true
                            }
                        } catch {
                            await MainActor.run {
                                showToast("Failed to create invite link.")
                            }
                        }
                    }
                    
                    private func copyInviteLinkToClipboard() async {
                        guard !inviteBusy else { return }
                        inviteBusy = true
                        defer { inviteBusy = false }
                        
                        do {
                            let inviteURL = try await createInviteRecord()
                            await MainActor.run {
                                UIPasteboard.general.string = inviteURL.absoluteString
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    copiedBanner = true
                                }
                            }
                            
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            
                            await MainActor.run {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    copiedBanner = false
                                }
                            }
                        } catch {
                            await MainActor.run {
                                showToast("Failed to copy invite link.")
                            }
                        }
                    }
                    
                    private func removeListeners() {
                        messageListener?.remove()
                        membersListener?.remove()
                        contributionsListener?.remove()
                        withdrawalsListener?.remove()
                        ledgerListener?.remove()
                        disputesListener?.remove()
                        
                        messageListener = nil
                        membersListener = nil
                        contributionsListener = nil
                        withdrawalsListener = nil
                        ledgerListener = nil
                        disputesListener = nil
                    }
                    
                    // MARK: Helpers
                    
                    private func initials(from s: String) -> String {
                        let parts = s.split(separator: " ").map(String.init)
                        let a = parts.first?.first.map(String.init) ?? "N"
                        let b = (parts.count > 1 ? parts[1].first.map(String.init) : nil) ?? ""
                        return (a + b).uppercased()
                    }
                    
                    private func formatAmount(_ value: Double) -> String {
                        let f = NumberFormatter()
                        f.numberStyle = .decimal
                        f.maximumFractionDigits = 2
                        return f.string(from: NSNumber(value: value)) ?? "\(value)"
                    }
                    
                    private func timestampText(from ts: Timestamp?) -> String {
                        guard let ts else { return "Now" }
                        let formatter = DateFormatter()
                        formatter.timeStyle = .short
                        formatter.dateStyle = .none
                        return formatter.string(from: ts.dateValue())
                    }
                    
                    private func toMillis(_ ts: Timestamp?) -> Int64 {
                        guard let ts else { return 0 }
                        return Int64(ts.seconds) * 1000 + Int64(ts.nanoseconds) / 1_000_000
                    }
                    
                    private func numericValue(_ any: Any?) -> Double {
                        if let n = any as? Double { return n }
                        if let n = any as? Int { return Double(n) }
                        if let n = any as? NSNumber { return n.doubleValue }
                        if let s = any as? String, let v = Double(s) { return v }
                        return 0
                    }
                    
                    private func shortUid(_ uid: String) -> String {
                        guard uid.count > 8 else { return uid }
                        return String(uid.prefix(4)) + "…" + String(uid.suffix(3))
                    }
                    
                    private func ledgerLabel(for row: [String: Any]) -> String {
                        let type = ((row["type"] as? String) ?? "").uppercased()
                        let amount = numericValue(row["amount"])
                        let cur = ((row["currency"] as? String) ?? "").uppercased()
                        
                        switch type {
                        case "CYCLE_CREATED", "CYCLE_CONFIGURED":
                            return "Cycle configured"
                        case "CONTRIBUTION_MANUAL":
                            return "Manual contribution recorded"
                        case "PAYOUT_INTENT_CREATED":
                            return "Payout slot created"
                        case "PAYOUT_PAUSED":
                            return "Payout paused"
                        case "PAYOUT_RESUMED":
                            return "Payout resumed"
                        case "PAYOUT_APPROVED_MANUAL":
                            return "Payout approved (manual)"
                        case "PAYEE_SWAPPED":
                            return "Payee swapped"
                        case "WALLET_TOPUP":
                            return "Wallet top-up"
                        case "WALLET_DEBIT":
                            return "Wallet debit"
                        default:
                            if amount > 0, !cur.isEmpty {
                                return "\(cur) \(formatAmount(amount)) · \(type.isEmpty ? "Ledger" : type)"
                            }
                            return type.isEmpty ? "Ledger event" : type
                        }
                    }
                    
                    private func ledgerDetail(for row: [String: Any]) -> String {
                        var pieces: [String] = []
                        
                        if let note = row["note"] as? String, !note.isEmpty { pieces.append(note) }
                        if let roundIndex = row["roundIndex"] { pieces.append("Round \(roundIndex)") }
                        if let roundId = row["roundId"] as? String, !roundId.isEmpty { pieces.append("Round ID \(shortUid(roundId))") }
                        if let payoutIntentId = row["payoutIntentId"] as? String, !payoutIntentId.isEmpty {
                            pieces.append("Payout \(shortUid(payoutIntentId))")
                        }
                        if let fromUid = row["fromUid"] as? String, !fromUid.isEmpty {
                            pieces.append("From \(shortUid(fromUid))")
                        }
                        if let toUid = row["toUid"] as? String, !toUid.isEmpty {
                            pieces.append("To \(shortUid(toUid))")
                        }
                        if let actorUid = row["actorUid"] as? String, !actorUid.isEmpty {
                            pieces.append("By \(shortUid(actorUid))")
                        }
                        
                        return pieces.joined(separator: " • ")
                    }
                }
                
                // MARK: Message UI
                
                private struct CommunityMessageRow: Identifiable {
                    let id: String
                    let senderName: String
                    let senderUid: String
                    let senderPhotoURL: String?
                    let senderPhotoPath: String?
                    let text: String
                    let gifURL: String?
                    let replyToSenderName: String?
                    let replyPreview: String?
                    let reactionCounts: [String: Int]
                    let myReactionKeys: Set<String>
                    let isCurrentUser: Bool
                    let timestampText: String
                    let createdAt: Timestamp?
                }
                
                private struct CommunityMessageBubble: View {
                    let message: CommunityMessageRow
                    var onReplyTap: () -> Void
                    var onReactTap: (String) -> Void
                    
                    @State private var resolvedStorageURL: URL?
                    
                    var body: some View {
                        let style = bubbleStyle(for: message.senderUid, isCurrentUser: message.isCurrentUser)
                        
                        HStack(alignment: .bottom, spacing: 10) {
                            if message.isCurrentUser {
                                Spacer(minLength: 44)
                            } else {
                                avatar
                            }
                            
                            VStack(alignment: message.isCurrentUser ? .trailing : .leading, spacing: 6) {
                                Text(displayName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.gray)
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    if let replyToSenderName = message.replyToSenderName,
                                       let replyPreview = message.replyPreview,
                                       !replyToSenderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                       !replyPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Replying to \(replyToSenderName)")
                                                .font(.caption2.bold())
                                                .foregroundColor(message.isCurrentUser ? .black.opacity(0.75) : .white.opacity(0.85))
                                            Text(replyPreview)
                                                .font(.caption2)
                                                .foregroundColor(message.isCurrentUser ? .black.opacity(0.65) : .white.opacity(0.72))
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(message.isCurrentUser ? Color.black.opacity(0.06) : Color.white.opacity(0.07))
                                        )
                                    }
                                    
                                    if let gifURL = message.gifURL,
                                       !gifURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        AnimatedGIFView(urlString: gifURL)
                                            .frame(width: 220, height: 160)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    
                                    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(message.text)
                                            .font(.subheadline)
                                            .foregroundColor(message.isCurrentUser ? .black : .white)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(style.fill)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(style.stroke, lineWidth: 1)
                                )
                                .shadow(color: style.glow, radius: 14, x: 0, y: 4)
                                .onTapGesture {
                                    onReplyTap()
                                }
                                
                                HStack(spacing: 8) {
                                    reactionPill(key: "fire", emoji: "🔥")
                                    reactionPill(key: "clap", emoji: "👏")
                                    reactionPill(key: "joy", emoji: "😂")
                                    reactionPill(key: "heart", emoji: "❤️")
                                    
                                    Button(action: onReplyTap) {
                                        Image(systemName: "arrowshape.turn.up.left.fill")
                                            .font(.caption.bold())
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(Color.white.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                Text(message.timestampText)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: 300, alignment: message.isCurrentUser ? .trailing : .leading)
                            
                            if message.isCurrentUser {
                                avatar
                            } else {
                                Spacer(minLength: 44)
                            }
                        }
                        .task {
                            await resolveStoragePhotoIfNeeded()
                        }
                    }
                    
                    private var displayName: String {
                        let trimmed = message.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "Member" : trimmed
                    }
                    
                    private func reactionPill(key: String, emoji: String) -> some View {
                        let count = message.reactionCounts[key] ?? 0
                        let active = message.myReactionKeys.contains(key)
                        
                        return Button {
                            onReactTap(key)
                        } label: {
                            HStack(spacing: 4) {
                                Text(emoji)
                                    .font(.caption)
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(active ? Color.white.opacity(0.14) : Color.white.opacity(0.07)))
                            .overlay(
                                Capsule().stroke(active ? Color.white.opacity(0.22) : Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    private func bubbleStyle(for uid: String, isCurrentUser: Bool) -> (fill: AnyShapeStyle, stroke: Color, glow: Color) {
                        if isCurrentUser {
                            return (
                                AnyShapeStyle(Color.white),
                                Color.white.opacity(0.28),
                                Color.white.opacity(0.16)
                            )
                        }
                        
                        let palette: [(Color, Color, Color)] = [
                            (Color.cyan.opacity(0.20), Color.blue.opacity(0.12), Color.cyan.opacity(0.16)),
                            (Color.purple.opacity(0.20), Color.indigo.opacity(0.12), Color.purple.opacity(0.16)),
                            (Color.green.opacity(0.18), Color.mint.opacity(0.10), Color.green.opacity(0.14)),
                            (Color.orange.opacity(0.18), Color.yellow.opacity(0.10), Color.orange.opacity(0.14)),
                            (Color.pink.opacity(0.18), Color.red.opacity(0.10), Color.pink.opacity(0.14))
                        ]
                        
                        let index = abs(uid.hashValue) % palette.count
                        let choice = palette[index]
                        
                        return (
                            AnyShapeStyle(
                                LinearGradient(
                                    colors: [choice.0, choice.1],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            ),
                            Color.white.opacity(0.10),
                            choice.2
                        )
                    }
                    
                    @ViewBuilder
                    private var avatar: some View {
                        if let urlString = message.senderPhotoURL, let url = URL(string: urlString), !urlString.isEmpty {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                default:
                                    initialsAvatar
                                }
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                        } else if let resolvedStorageURL {
                            AsyncImage(url: resolvedStorageURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                default:
                                    initialsAvatar
                                }
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                        } else {
                            initialsAvatar
                        }
                    }
                    
                    private var initialsAvatar: some View {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.10))
                            Text(initials(from: displayName))
                                .foregroundColor(.white)
                                .font(.caption.bold())
                        }
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                    }
                    
                    private func initials(from s: String) -> String {
                        let parts = s.split(separator: " ").map(String.init)
                        let a = parts.first?.first.map(String.init) ?? "M"
                        let b = (parts.count > 1 ? parts[1].first.map(String.init) : nil) ?? ""
                        return (a + b).uppercased()
                    }
                    
                    private func resolveStoragePhotoIfNeeded() async {
                        guard resolvedStorageURL == nil else { return }
                        guard (message.senderPhotoURL ?? "").isEmpty else { return }
                        guard let path = message.senderPhotoPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return }
                        
                        do {
                            let ref = Storage.storage().reference(withPath: path)
                            let url = try await ref.downloadURL()
                            await MainActor.run {
                                resolvedStorageURL = url
                            }
                        } catch {
                            // silent fallback
                        }
                    }
                }
                
                private struct AnimatedGIFView: UIViewRepresentable {
                    let urlString: String
                    
                    func makeUIView(context: Context) -> WKWebView {
                        let webView = WKWebView(frame: .zero)
                        webView.isOpaque = false
                        webView.backgroundColor = .clear
                        webView.scrollView.isScrollEnabled = false
                        webView.scrollView.backgroundColor = .clear
                        return webView
                    }
                    
                    func updateUIView(_ webView: WKWebView, context: Context) {
                        let safeURLString = urlString
                            .replacingOccurrences(of: "&", with: "&amp;")
                            .replacingOccurrences(of: "\"", with: "&quot;")
                            .replacingOccurrences(of: "'", with: "&#39;")
                            .replacingOccurrences(of: "<", with: "&lt;")
                            .replacingOccurrences(of: ">", with: "&gt;")
                        
                        let html = """
        <html>
        <head>
        <meta name="viewport" content="initial-scale=1.0, maximum-scale=1.0">
        <style>
        body { margin:0; background:transparent; overflow:hidden; }
        img { width:100%; height:100%; object-fit:cover; border-radius:16px; }
        </style>
        </head>
        <body>
            <img src="\(safeURLString)" />
        </body>
        </html>
        """
                        webView.loadHTMLString(html, baseURL: nil)
                    }
                }
                
                private struct MemberRowView: View {
                    let member: NjangiCommunityTerminalView.CommunityMember
                    
                    @State private var resolvedStorageURL: URL?
                    
                    var body: some View {
                        HStack(spacing: 12) {
                            avatar
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.name)
                                    .foregroundColor(.white)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                
                                Text(member.role.capitalized)
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            }
                            
                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .task {
                            await resolveStoragePhotoIfNeeded()
                        }
                    }
                    
                    @ViewBuilder
                    private var avatar: some View {
                        if let urlString = member.photoURL, let url = URL(string: urlString), !urlString.isEmpty {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    initialsAvatar
                                }
                            }
                            .frame(width: 42, height: 42)
                            .clipShape(Circle())
                        } else if let resolvedStorageURL {
                            AsyncImage(url: resolvedStorageURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    initialsAvatar
                                }
                            }
                            .frame(width: 42, height: 42)
                            .clipShape(Circle())
                        } else {
                            initialsAvatar
                        }
                    }
                    
                    private var initialsAvatar: some View {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.10))
                            Text(initials(from: member.name))
                                .foregroundColor(.white)
                                .font(.caption.bold())
                        }
                        .frame(width: 42, height: 42)
                    }
                    
                    private func initials(from s: String) -> String {
                        let parts = s.split(separator: " ").map(String.init)
                        let a = parts.first?.first.map(String.init) ?? "M"
                        let b = (parts.count > 1 ? parts[1].first.map(String.init) : nil) ?? ""
                        return (a + b).uppercased()
                    }
                    
                    private func resolveStoragePhotoIfNeeded() async {
                        guard resolvedStorageURL == nil else { return }
                        guard (member.photoURL ?? "").isEmpty else { return }
                        guard let path = member.photoPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return }
                        
                        do {
                            let ref = Storage.storage().reference(withPath: path)
                            let url = try await ref.downloadURL()
                            await MainActor.run {
                                resolvedStorageURL = url
                            }
                        } catch {
                            // silent fallback
                        }
                    }
                }
                
                private struct ContributionRowView: View {
                    let row: NjangiCommunityTerminalView.FundContribution
                    
                    var body: some View {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "dollarsign.circle.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.currency.uppercased()) \(formatAmount(row.amount))")
                                    .foregroundColor(.white)
                                    .font(.subheadline.bold())
                                
                                Text(displayName)
                                    .foregroundColor(.gray)
                                    .font(.caption)
                                
                                if !row.reason.isEmpty {
                                    Text(row.reason)
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                                
                                if let ts = row.createdAt {
                                    Text(fullDateText(from: ts))
                                        .foregroundColor(.gray)
                                        .font(.caption2)
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    
                    private var displayName: String {
                        if !row.contributorName.isEmpty { return row.contributorName }
                        if !row.contributorEmail.isEmpty { return row.contributorEmail }
                        return row.contributorUid.isEmpty ? "Member" : row.contributorUid
                    }
                    
                    private func formatAmount(_ value: Double) -> String {
                        let f = NumberFormatter()
                        f.numberStyle = .decimal
                        f.maximumFractionDigits = 2
                        return f.string(from: NSNumber(value: value)) ?? "\(value)"
                    }
                    
                    private func fullDateText(from ts: Timestamp) -> String {
                        let formatter = DateFormatter()
                        formatter.dateStyle = .medium
                        formatter.timeStyle = .short
                        return formatter.string(from: ts.dateValue())
                    }
                }
                
                private struct WithdrawalRowView: View {
                    let row: NjangiCommunityTerminalView.WithdrawalRecord
                    
                    var body: some View {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("\(row.currency.uppercased()) \(formatAmount(row.amount))")
                                        .foregroundColor(.white)
                                        .font(.subheadline.bold())
                                    
                                    Text(row.status.capitalized)
                                        .font(.caption2.bold())
                                        .foregroundColor(statusColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(statusColor.opacity(0.12)))
                                }
                                
                                Text("Fee: \(row.currency.uppercased()) \(formatAmount(row.feeAmount)) • Net: \(row.currency.uppercased()) \(formatAmount(row.netAmount))")
                                    .foregroundColor(.gray)
                                    .font(.caption)
                                
                                if !row.reason.isEmpty {
                                    Text(row.reason)
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                                
                                if let ts = row.createdAt {
                                    Text(fullDateText(from: ts))
                                        .foregroundColor(.gray)
                                        .font(.caption2)
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    
                    private var statusColor: Color {
                        switch row.status.lowercased() {
                        case "paid":
                            return .green
                        case "blocked":
                            return .yellow
                        case "approved", "processing":
                            return .blue
                        default:
                            return .gray
                        }
                    }
                    
                    private func formatAmount(_ value: Double) -> String {
                        let f = NumberFormatter()
                        f.numberStyle = .decimal
                        f.maximumFractionDigits = 2
                        return f.string(from: NSNumber(value: value)) ?? "\(value)"
                    }
                    
                    private func fullDateText(from ts: Timestamp) -> String {
                        let formatter = DateFormatter()
                        formatter.dateStyle = .medium
                        formatter.timeStyle = .short
                        return formatter.string(from: ts.dateValue())
                    }
                }
                
                private struct GovernanceEventRowView: View {
                    let row: NjangiCommunityTerminalView.GovernanceEvent
                    
                    var body: some View {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: row.kind == "dispute" ? "exclamationmark.bubble.fill" : "scroll.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(row.title)
                                        .foregroundColor(.white)
                                        .font(.subheadline.bold())
                                    
                                    if let status = row.status, !status.isEmpty {
                                        Text(status.capitalized)
                                            .font(.caption2.bold())
                                            .foregroundColor(statusColor(status))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(statusColor(status).opacity(0.12)))
                                    }
                                }
                                
                                if !row.detail.isEmpty {
                                    Text(row.detail)
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                
                                if let ts = row.timestamp {
                                    Text(fullDateText(from: ts))
                                        .foregroundColor(.gray)
                                        .font(.caption2)
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    
                    private func statusColor(_ s: String) -> Color {
                        switch s.lowercased() {
                        case "open":
                            return .yellow
                        case "resolved":
                            return .green
                        case "dismissed":
                            return .gray
                        default:
                            return .blue
                        }
                    }
                    
                    private func fullDateText(from date: Date) -> String {
                        let formatter = DateFormatter()
                        formatter.dateStyle = .medium
                        formatter.timeStyle = .short
                        return formatter.string(from: date)
                    }
                }
                
                private struct SuggestedGIF: Identifiable {
                    let id = UUID()
                    let title: String
                    let urlString: String
                }
                
                private struct GIFSuggestionPickerView: View {
                    let suggestions: [SuggestedGIF]
                    var onSelect: (SuggestedGIF) -> Void
                    
                    @Environment(\.dismiss) private var dismiss
                    
                    private let columns = [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ]
                    
                    var body: some View {
                        NavigationStack {
                            ScrollView {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(suggestions) { gif in
                                        Button {
                                            onSelect(gif)
                                            dismiss()
                                        } label: {
                                            VStack(alignment: .leading, spacing: 8) {
                                                AnimatedGIFView(urlString: gif.urlString)
                                                    .frame(height: 130)
                                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                                
                                                Text(gif.title)
                                                    .font(.caption.bold())
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                            }
                                            .padding(10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                    .fill(Color.white.opacity(0.06))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(16)
                            }
                            .background(Color.black.ignoresSafeArea())
                            .navigationTitle("Choose a GIF")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Close") {
                                        dismiss()
                                    }
                                    .foregroundColor(.white)
                                }
                            }
                        }
                    }
                }
                
                private struct ActivityViewController: UIViewControllerRepresentable {
                    let activityItems: [Any]
                    
                    func makeUIViewController(context: Context) -> UIActivityViewController {
                        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
                    }
                    
                    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
                }
                
                // MARK: Web modal
                
                private struct NjangiWebModal: View {
                    let groupId: String
                    
                    var body: some View {
                        InAppSafariView(url: makeURL())
                            .ignoresSafeArea()
                    }
                    
                    private func makeURL() -> URL {
                        var c = URLComponents()
                        c.scheme = "https"
                        c.host = "black-app-web.web.app"
                        c.path = "/njangi"
                        c.queryItems = [
                            URLQueryItem(name: "groupId", value: groupId),
                            URLQueryItem(name: "screen", value: "community")
                        ]
                        return c.url ?? URL(string: "https://black-app-web.web.app/njangi")!
                    }
                }
                
                private struct InAppSafariView: UIViewControllerRepresentable {
                    let url: URL
                    
                    func makeUIViewController(context: Context) -> SFSafariViewController {
                        let config = SFSafariViewController.Configuration()
                        config.entersReaderIfAvailable = false
                        let vc = SFSafariViewController(url: url, configuration: config)
                        vc.dismissButtonStyle = .close
                        vc.preferredControlTintColor = .white
                        return vc
                    }
                    
                    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }
                }
            
    
