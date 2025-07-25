// UserWallView.swift
// Displays personalized feed based on selected interests, now backed by Firebase

import SwiftUI
import Firebase

struct UserWallView: View {
    let userId: String
    @State private var selectedCategories: Set<FeedCategory> = []
    @State private var feedItems: [FeedItem] = []
    @State private var showCategorySelector = false
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Your Wall")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button("Customize") {
                    showCategorySelector = true
                }
                .font(.caption)
            }
            .padding(.horizontal)

            if isLoading {
                ProgressView("Loading content...")
                    .padding()
            } else if feedItems.isEmpty {
                Text("No content yet. Choose topics to get started.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
            } else {
                ForEach(feedItems) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView()
                                case .success(let img):
                                    img.resizable().scaledToFill().frame(height: 180).clipped()
                                case .failure:
                                    Image(systemName: "photo")
                                        .resizable()
                                        .frame(width: 100, height: 100)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                            .cornerRadius(10)
                        }

                        Text(item.title)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .bold()

                        Text(item.description)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(3)

                        Link("View Original", destination: URL(string: item.link)!)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
            }
        }
        .onAppear {
            loadUserInterests()
        }
        .sheet(isPresented: $showCategorySelector) {
            WallInterestSelector(selectedCategories: $selectedCategories) {
                showCategorySelector = false
                fetchFeed()
                saveUserInterests()
            }
        }
    }

    private func fetchFeed() {
        isLoading = true
        SocialFeedAggregator.fetchFeeds(for: Array(selectedCategories)) { items in
            self.feedItems = items
            self.isLoading = false
        }
    }

    private func loadUserInterests() {
        let ref = Database.database().reference()
            .child("users/\(userId)/wallPreferences/categories")

        ref.observeSingleEvent(of: .value) { snapshot in
            if let values = snapshot.value as? [String] {
                selectedCategories = Set(values.compactMap { FeedCategory(rawValue: $0) })
                fetchFeed()
            } else {
                showCategorySelector = true
            }
        }
    }

    private func saveUserInterests() {
        let values = selectedCategories.map { $0.rawValue }
        let ref = Database.database().reference()
            .child("users/\(userId)/wallPreferences/categories")
        ref.setValue(values)
    }
} 
