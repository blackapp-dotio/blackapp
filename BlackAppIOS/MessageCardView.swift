import SwiftUI
import Firebase

struct MessageCardView: View {
    let message: ChatMessage
    let isSender: Bool
    let toggleLike: () -> Void
    let commentAction: () -> Void
    let repostAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Circle()
                    .fill(isSender ? Color.blue : Color.purple)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(initials(from: message.senderName))
                            .font(.caption)
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    if let text = message.text {
                        Text(text)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isSender ? Color.blue.opacity(0.2) : Color.gray.opacity(0.3))
                            )
                    }

                    if let mediaURL = message.mediaURL, let url = URL(string: mediaURL) {
                        if message.type == "image" {
                            AsyncImage(url: url) { img in
                                img.resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .cornerRadius(10)
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(maxHeight: 200)
                        } else if message.type == "video" {
                            VideoPlayerView(videoURL: url)
                                .frame(height: 200)
                        }
                    }

                    HStack(spacing: 20) {
                        Button(action: toggleLike) {
                            Label("\(message.likes.count)", systemImage: "heart")
                        }
                        .foregroundColor(.white)

                        Button(action: commentAction) {
                            Label("\(message.comments.count)", systemImage: "bubble.right")
                        }
                        .foregroundColor(.white)

                        Button(action: repostAction) {
                            Label("\(message.reposts.count)", systemImage: "arrow.2.squarepath")
                        }
                        .foregroundColor(.white)
                    }
                    .font(.footnote)
                    .padding(.top, 4)
                }
            }
        }
    }

    // Provide a simple fallback for initials
    func initials(from name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let second = parts.dropFirst().first?.prefix(1) ?? ""
        return (first + second).uppercased()
    }
}
