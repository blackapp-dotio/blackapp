import SwiftUI

struct RSSCardView: View {
    let article: RSSArticle
    @Binding var selectedURL: URL?
    @Binding var showWebView: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = article.imageURL {
                AsyncImage(url: url) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(10)
                } placeholder: {
                    Rectangle()
                        .foregroundColor(.gray.opacity(0.3))
                        .frame(height: 200)
                        .cornerRadius(10)
                }
            }

            Text(article.title)
                .font(.headline)
                .foregroundColor(.white)

            Text(article.description)
                .font(.subheadline)
                .foregroundColor(.gray)
                .lineLimit(3)

            Button("Read More") {
                selectedURL = URL(string: article.link)
                showWebView = true
            }
            .font(.caption)
            .foregroundColor(.blue)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.black)
    }
}
