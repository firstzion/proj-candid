import SwiftUI

struct FeedView: View {
    @State private var posts: [FeedPost] = []
    @State private var phase: Phase = .loading
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    /// Deliberately small so pagination is easy to trigger and verify by
    /// hand, rather than matching `FeedService.defaultLimit`.
    private static let pageSize = 8

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView()

                case .loaded where posts.isEmpty:
                    ContentUnavailableView("No Posts Yet", systemImage: "photo.on.rectangle.angled")

                case .loaded:
                    List {
                        ForEach(posts) { post in
                            PostRow(post: post)
                                .onAppear {
                                    if post.id == posts.last?.id {
                                        Task { await loadMore() }
                                    }
                                }
                        }

                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await refresh() }

                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Feed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await refresh() } }
                    }
                }
            }
            .navigationTitle("Feed")
            .task {
                guard posts.isEmpty else { return }
                await refresh()
            }
        }
    }

    /// Fetches the newest page and merges it in — used for both the initial
    /// load and pull-to-refresh, which are the same operation: ask for the
    /// newest posts again and reconcile against what's already on screen.
    private func refresh() async {
        do {
            let page = try await FeedService().fetchPosts(limit: Self.pageSize)
            merge(page, at: .start)
            phase = .loaded
        } catch {
            // A failed refresh with posts already on screen just leaves them
            // there — the pull-to-refresh spinner dismisses and the user can
            // try again, rather than the whole feed being replaced by an
            // error screen over content that was working fine a moment ago.
            if posts.isEmpty {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, !reachedEnd else { return }
        isLoadingMore = true

        if let page = try? await FeedService().fetchPosts(before: posts.last?.cursor, limit: Self.pageSize) {
            merge(page, at: .end)
            if page.count < Self.pageSize {
                reachedEnd = true
            }
        }
        // A transient failure here just leaves `reachedEnd` false, so
        // scrolling back to the last row (or pulling to refresh) tries
        // again rather than the feed being stuck or erroring out wholesale.

        isLoadingMore = false
    }

    private enum MergePosition {
        case start
        case end
    }

    /// Adds only posts not already on screen, so refreshing or paginating
    /// never duplicates a row already loaded from an earlier fetch.
    private func merge(_ page: [FeedPost], at position: MergePosition) {
        let existingIDs = Set(posts.map(\.id))
        let newOnes = page.filter { !existingIDs.contains($0.id) }
        guard !newOnes.isEmpty else { return }

        switch position {
        case .start:
            posts = newOnes + posts
        case .end:
            posts += newOnes
        }
    }
}

private struct PostRow: View {
    let post: FeedPost

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(post.username)
                .font(.headline)

            AsyncImage(url: post.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                @unknown default:
                    EmptyView()
                }
            }

            if let caption = post.caption {
                Text(caption)
            }

            Text(post.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    FeedView()
}
