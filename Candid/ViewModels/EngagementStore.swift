import Foundation
import Observation

/// What `EngagementStore.toggleLike` needs from a service. `LikeService` is
/// the only real conformer; the protocol lets a test fail or hold a request
/// without a stubbed HTTP round trip, the way `PostsPaging` does for pages.
protocol PostLiking: Sendable {
    func like(post postID: UUID) async throws
    func unlike(post postID: UUID) async throws
}

/// Optimistic like and comment counts, layered over what the server said
/// (SOL-89).
///
/// A post's numbers arrive with its row (`FeedPost.engagement`), and the
/// same post can be on screen twice — a feed row, and the detail view opened
/// from a profile grid, each holding its own copy. Marking the feed stale
/// after every tap would refetch and re-sign a whole page per like, so
/// instead each screen reads through this store: an override, keyed by post
/// id, remembers the server row it was derived from and applies only while
/// the row on screen still matches it. When a refresh brings a row that says
/// something different, that row wins on its own — no hook into
/// `PagedPosts`, nothing to clear. Comment likes need none of this: they
/// show on one screen, and `CommentsModel` keeps them in place.
///
/// Lives in the environment beside `FeedInvalidation`. The service is a
/// parameter rather than a stored dependency, like `feedInvalidation` on
/// `ProfileModel`, so the store constructs with no arguments in previews and
/// tests.
@MainActor
@Observable
final class EngagementStore {
    /// An optimistic value and the server row it was derived from.
    struct Override: Equatable {
        let base: PostEngagement
        var current: PostEngagement
    }

    private(set) var overrides: [UUID: Override] = [:]

    /// Posts with a like request in flight. A second tap while one is out is
    /// ignored rather than raced: a like and an unlike completing out of
    /// order would leave the screen and the server disagreeing. Observed,
    /// not ignored, so the heart re-enables when the request lands.
    private var inFlight: Set<UUID> = []

    /// What to show for `post`: its override if that was derived from the
    /// very row on screen, otherwise the row itself.
    func engagement(for post: FeedPost) -> PostEngagement {
        if let override = overrides[post.id], override.base == post.engagement {
            return override.current
        }
        return post.engagement
    }

    func isBusy(_ postID: UUID) -> Bool {
        inFlight.contains(postID)
    }

    /// Flips the like at once, then asks the server. On failure what was
    /// shown before the tap comes back, and the message is returned for the
    /// view to show. Returns nil on success, and nil without acting when a
    /// request is already in flight for this post.
    func toggleLike(on post: FeedPost, using liker: any PostLiking) async -> String? {
        guard !inFlight.contains(post.id) else { return nil }
        inFlight.insert(post.id)
        defer { inFlight.remove(post.id) }

        let shown = engagement(for: post)
        var optimistic = shown
        optimistic.isLikedByViewer.toggle()
        optimistic.likeCount = max(0, shown.likeCount + (optimistic.isLikedByViewer ? 1 : -1))
        overrides[post.id] = Override(base: post.engagement, current: optimistic)

        do {
            if optimistic.isLikedByViewer {
                try await liker.like(post: post.id)
            } else {
                try await liker.unlike(post: post.id)
            }
            return nil
        } catch {
            restore(shown, for: post)
            return error.localizedDescription
        }
    }

    /// The thread added a comment to `post` (SOL-90).
    func commentAdded(to post: FeedPost) {
        adjustCommentCount(of: post, by: 1)
    }

    /// The thread removed a comment from `post` (SOL-90).
    func commentRemoved(from post: FeedPost) {
        adjustCommentCount(of: post, by: -1)
    }

    private func adjustCommentCount(of post: FeedPost, by delta: Int) {
        var next = engagement(for: post)
        next.commentCount = max(0, next.commentCount + delta)
        overrides[post.id] = Override(base: post.engagement, current: next)
    }

    /// Puts back what was shown before a failed tap. When that was the row's
    /// own value there is nothing left to remember, so the override goes.
    private func restore(_ shown: PostEngagement, for post: FeedPost) {
        if shown == post.engagement {
            overrides[post.id] = nil
        } else {
            overrides[post.id] = Override(base: post.engagement, current: shown)
        }
    }
}
