import SwiftUI

/// Temporary debug view for `FeedService` (SOL-13) — enough to see the query,
/// join, and pagination working, with nothing styled. SOL-14 replaces this
/// with the real feed UI.
struct FeedView: View {
    @State private var posts: [FeedPost] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var reachedEnd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(posts) { post in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(post.username).font(.headline)
                        if let caption = post.caption {
                            Text(caption)
                        }
                        Text(post.createdAt, format: .dateTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        AsyncImage(url: post.imageURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(maxHeight: 160)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                if !reachedEnd {
                    Button("Load More") {
                        Task { await loadMore() }
                    }
                    .disabled(isLoading)
                }
            }
            .navigationTitle("Feed (debug)")
            .task {
                guard posts.isEmpty else { return }
                await loadMore()
            }
            .refreshable {
                posts = []
                reachedEnd = false
                await loadMore()
            }
        }
    }

    private func loadMore() async {
        isLoading = true
        errorMessage = nil

        do {
            // Small limit so a couple of taps on "Load More" exercises
            // pagination by hand.
            let page = try await FeedService().fetchPosts(before: posts.last?.cursor, limit: 3)
            posts.append(contentsOf: page)
            if page.isEmpty {
                reachedEnd = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

#Preview {
    FeedView()
}
