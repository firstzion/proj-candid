import SwiftUI

struct FeedView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var posts: [FeedPost] = []
    @State private var phase: Phase = .loading
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

    /// When the posts on screen were fetched. Their signed image URLs stop
    /// resolving `StorageService.signedURLLifetime` after this — see `isStale`.
    @State private var loadedAt: Date?

    /// Bumped by every successful refresh. A `loadMore` that was in flight
    /// across a refresh checks it on return and drops its page: that page was
    /// paginated from a cursor that is no longer in the list, and appending
    /// it would leave a hole between the fresh head and the old tail.
    @State private var generation = 0

    /// Why the last `loadMore` failed, shown as a retry row under the posts.
    /// Swallowing it left someone parked at the bottom with no spinner, no
    /// message and nothing to tap — the last row's `onAppear` does not fire
    /// again until it scrolls off and back on.
    @State private var loadMoreError: String?

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    /// Posts per page. Each page costs two round trips — the rows, then their
    /// signed URLs — so this is the service's default rather than the value of
    /// 8 that had been left in from verifying pagination by hand.
    private static let pageSize = FeedService.defaultLimit

    /// How old the feed may get before it refreshes itself. Half the signed
    /// URL lifetime, so images are swapped for fresh URLs well before the
    /// current ones expire — rather than every photo on screen turning into a
    /// placeholder at the hour mark.
    private static let staleAfter = TimeInterval(StorageService.signedURLLifetime) / 2

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
                            FeedPostRow(post: post)
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
                        } else if let loadMoreError {
                            VStack(spacing: 8) {
                                Text(loadMoreError)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                Button("Try Again") { Task { await loadMore() } }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
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
                // Runs every time the tab is shown; only fetch when there is
                // nothing on screen or what's there has gone stale.
                guard posts.isEmpty || isStale else { return }
                await refresh()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Returning from the background after a long absence is how
                // the feed usually goes stale — and `.task` does not re-run
                // for that, only for the tab appearing.
                guard newPhase == .active, isStale else { return }
                Task { await refresh() }
            }
        }
    }

    private var isStale: Bool {
        guard let loadedAt else { return false }
        return Date().timeIntervalSince(loadedAt) > Self.staleAfter
    }

    /// Fetches the newest page and replaces the feed with it — the initial
    /// load, pull-to-refresh, and the automatic refresh of a stale feed are
    /// all the same operation.
    ///
    /// Replacing rather than merging is deliberate, for two reasons. Signed
    /// image URLs expire, and a merge that kept the existing posts kept their
    /// dead URLs too, so after an hour every image was a placeholder and
    /// pulling to refresh could not fix it. And a merge that only prepends
    /// what's new leaves a hole whenever more than a page of posts arrived
    /// since the last load: the posts between the new head and the old list
    /// were never fetched, and `loadMore` only ever paginates from the end.
    /// Starting over from the newest page has neither problem; older pages
    /// are re-fetched as the user scrolls.
    private func refresh() async {
        do {
            let page = try await FeedService().fetchPosts(limit: Self.pageSize)
            generation += 1
            posts = page.posts
            loadedAt = Date()
            reachedEnd = !page.hasMore
            loadMoreError = nil
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
        loadMoreError = nil
        defer { isLoadingMore = false }

        let startedIn = generation
        let page: FeedPage
        do {
            page = try await FeedService().fetchPosts(before: posts.last?.cursor, limit: Self.pageSize)
        } catch {
            // `reachedEnd` stays false, so the retry row under the posts — or
            // scrolling the last one off and back on, or pulling to refresh —
            // tries again, rather than the whole feed erroring out over
            // content that is fine.
            guard startedIn == generation else { return }
            loadMoreError = error.localizedDescription
            return
        }

        // The feed was refreshed underneath this request — see `generation`.
        guard startedIn == generation else { return }

        append(page.posts)
        reachedEnd = !page.hasMore
    }

    /// Appends only posts not already on screen. Keyset pagination should
    /// never hand back a row twice, but a duplicate `id` in a `List` is a
    /// runtime warning and a misrendered row, so the check is cheap insurance.
    private func append(_ page: [FeedPost]) {
        let existingIDs = Set(posts.map(\.id))
        posts += page.filter { !existingIDs.contains($0.id) }
    }
}

/// One post in the list. Not to be confused with `FeedService`'s row decoder,
/// which is also a "post row" — this one is the view.
private struct FeedPostRow: View {
    let post: FeedPost

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(post.username)
                .font(.headline)

            if let imageURL = post.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        missingImage
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                // The object behind this post could not be signed — see
                // `FeedPost.imageURL`. Handled here because `AsyncImage` given
                // a nil URL never leaves `.empty`: a spinner that never stops.
                missingImage
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

    private var missingImage: some View {
        Image(systemName: "photo")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 200)
    }
}

#Preview {
    FeedView()
}
