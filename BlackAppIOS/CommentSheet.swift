import SwiftUI
import FirebaseDatabase
import FirebaseAuth

struct Comment: Identifiable {
    let id: String
    let userId: String
    let text: String
    let timestamp: TimeInterval
}

struct CommentSheet: View {
    let postId: String
    @State private var newComment = ""
    @State private var comments: [Comment] = []

    var body: some View {
        NavigationView {
            VStack {
                List(comments.sorted(by: { $0.timestamp < $1.timestamp })) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(comment.text)
                            .foregroundColor(.white)
                            .font(.body)
                        Text("Posted by: \(comment.userId.prefix(6))...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
                .background(Color.black)

                HStack {
                    TextField("Write a comment...", text: $newComment)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .foregroundColor(.white)

                    Button("Send") {
                        postComment()
                    }
                    .disabled(newComment.isEmpty)
                }
                .padding()
            }
            .background(Color.black)
            .onAppear {
                fetchComments()
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    func fetchComments() {
        let ref = Database.database().reference().child("posts/\(postId)/comments")
        ref.observe(.value) { snapshot in
            var loaded: [Comment] = []
            for child in snapshot.children {
                if let snap = child as? DataSnapshot,
                   let dict = snap.value as? [String: Any],
                   let text = dict["text"] as? String,
                   let userId = dict["userId"] as? String,
                   let timestamp = dict["timestamp"] as? TimeInterval {
                    let comment = Comment(id: snap.key, userId: userId, text: text, timestamp: timestamp)
                    loaded.append(comment)
                }
            }
            self.comments = loaded
        }
    }

    func postComment() {
        guard !newComment.isEmpty, let currentUser = Auth.auth().currentUser else { return }
        let ref = Database.database().reference().child("posts/\(postId)/comments").childByAutoId()
        let data: [String: Any] = [
            "text": newComment,
            "userId": currentUser.uid,
            "timestamp": Date().timeIntervalSince1970
        ]
        ref.setValue(data)
        newComment = ""
    }
}

