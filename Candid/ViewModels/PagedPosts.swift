import Foundation
import Observation

/// Where a `PagedPosts` gets its pages. `FeedService` is the only real
/// conformer; the point of the protocol is that a test can hand over a page
/// on its own schedule — holding one `fetchPosts` open while a refresh
/// completes is how the `generation` guard below is proved, and that is
/// awkward to stage through canned HTTP responses.
protocol PostsPaging: Sendable {
    func fetchPosts(by authorID: UUID?, before cursor: FeedCursor?, limit: Int) async throws -> FeedPage
}

/// One page-at-a-time list of posts — the whole feed, or one author's grid.
///
/// The feed and the profile grid each carried a private copy of this: the
/// same `posts`, `reachedEnd`, `isLoadingMore`, the same generation counter,
/// the same id-dedupe on append. They had already drifted — the feed offered
/// a retry when a page failed and the grid only reported it — which is the
/// usual way two copies of subtle logic go wrong, and neither copy could be
/// tested, because both lived in a `View`.
///
/// The two behaviours worth knowing about, both carried over unchanged from
/// `FeedView`, are documented on `refresh()` and `generation`.
@MainActor
@Observable
final class PagedPosts {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var posts: [FeedPost] = []
    private(set) var phase: Phase = .loading
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false

    /// Why the last `loadMore` failed, for the retry row under the list.
    /// Swallowing it left someone parked at the bottom with no spinner, no
    /// message and nothing to tap — the last row's `onAppear` does not fire
    /// again until it scrolls off and back on.
    private(set) var loadMoreError: String?

    /// When the posts on screen were fetched. Their signed image URLs stop
    /// resolving `StorageService.signedURLLifetime` after this — see
    /// `isStale(after:now:)`.
    private(set) var loadedAt: Date?

    /// Nil for the feed; a profile's id for that person's grid. A *scope*,
    /// not a rule: RLS still decides which of their rows exist for the
    /// caller. Readable so a view holding a model for one person can tell it
    /// is not the one it now needs.
    let authorID: UUID?

    private let source: any PostsPaging
    private let pageSize: Int

    /// Bumped by every successful refresh. A `loadMore` that was in flight
    /// across a refresh checks it on return and drops its page: that page was
    /// paginated from a cursor that is no longer in the list, and appending
    /// it would leave a hole between the fresh head and the old tail.
    @ObservationIgnored private var generation = 0

    init(source: any PostsPaging, authorID: UUID? = nil, pageSize: Int = FeedService.defaultLimit) {
        self.source = source
        self.authorID = authorID
        self.pageSize = pageSize
    }

    /// Fetches the newest page and replaces the list with it — the initial
    /// load, pull-to-refresh, and the automatic refresh of a stale list are
    /// all the same operation. Returns the page so a caller can decide an
    /// empty state from it; nil when the fetch failed.
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
    @discardableResult
    func refresh() async -> FeedPage? {
        do {
            let page = try await source.fetchPosts(by: authorID, before: nil, limit: pageSize)
            generation += 1
            posts = page.posts
            loadedAt = Date()
            reachedEnd = !page.hasMore
            loadMoreError = nil
            phase = .loaded
            return page
        } catch {
            // A failed refresh with posts already on screen just leaves them
            // there — the pull-to-refresh spinner dismisses and the person can
            // try again, rather than the whole list being replaced by an error
            // screen over content that was working fine a moment ago.
            if posts.isEmpty {
                phase = .failed(error.localizedDescription)
            }
            return nil
        }
    }

    /// The next page, from the last post's cursor. A failure leaves
    /// `reachedEnd` false, so the retry row — or scrolling the last row off
    /// and back on, or pulling to refresh — tries again, rather than the whole
    /// list erroring out over content that is fine.
    func loadMore() async {
        guard !isLoadingMore, !reachedEnd else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }

        let startedIn = generation
        let page: FeedPage
        do {
            page = try await source.fetchPosts(by: authorID, before: posts.last?.cursor, limit: pageSize)
        } catch {
            guard startedIn == generation else { return }
            loadMoreError = error.localizedDescription
            return
        }

        // The list was refreshed underneath this request — see `generation`.
        guard startedIn == generation else { return }

        append(page.posts)
        reachedEnd = !page.hasMore
    }

    /// Takes a post out at once — before the server has been asked — and
    /// returns where it was, so a refusal can put it back exactly there.
    @discardableResult
    func remove(id: UUID) -> Int? {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return nil }
        posts.remove(at: index)
        return index
    }

    /// Puts a post back after a failed delete. A nil index, or one past the
    /// end because the list was refreshed in the meantime, appends.
    func insert(_ post: FeedPost, at index: Int?) {
        posts.insert(post, at: min(index ?? posts.count, posts.count))
    }

    /// Whether what is on screen is old enough to be worth refetching —
    /// chiefly because its signed image URLs are approaching expiry. False
    /// before anything has loaded: there is nothing stale about an empty list.
    func isStale(after interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let loadedAt else { return false }
        return now.timeIntervalSince(loadedAt) > interval
    }

    /// Appends only posts not already on screen. Keyset pagination should
    /// never hand back a row twice, but a duplicate `id` in a `List` is a
    /// runtime warning and a misrendered row, so the check is cheap insurance.
    private func append(_ page: [FeedPost]) {
        let existingIDs = Set(posts.map(\.id))
        posts += page.filter { !existingIDs.contains($0.id) }
    }
}
