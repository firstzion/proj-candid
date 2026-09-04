import Foundation

/// One post as shown in the feed: a `posts` row joined with its author's
/// `profiles.username`, carrying a ready-to-display signed URL for the image
/// rather than the raw storage path — see `StorageService`, which mints it.
struct FeedPost: Identifiable, Equatable {
    let id: UUID

    /// Nil when the object could not be signed — most likely it no longer
    /// exists. The post is still shown, with a placeholder, rather than
    /// dropped: its author and caption are real content, and dropping rows
    /// made a page look shorter than it was, which the feed read as the end.
    let imageURL: URL?

    let caption: String?
    let createdAt: Date
    let username: String

    /// The cursor for fetching the page after this post — see
    /// `FeedService.fetchPosts(before:limit:)`. Carried as a stored property,
    /// set from the row's raw `created_at` text, rather than derived from
    /// `createdAt`: see `FeedCursor` for why re-deriving it is unsafe.
    let cursor: FeedCursor
}

/// One page of the feed, from `FeedService.fetchPosts(before:limit:)`.
struct FeedPage: Equatable {
    let posts: [FeedPost]

    /// Whether a page exists after `posts.last`. Decided from the rows the
    /// query returned — it asks for one more than the page size, and whether
    /// that extra row came back is the answer — never from `posts.count`, so
    /// nothing about how a page was assembled can make the feed look finished
    /// early.
    let hasMore: Bool
}

/// A keyset pagination cursor: the `(created_at, id)` of the last post seen.
///
/// Paginating on `created_at` alone can drop or repeat a row if two posts
/// ever share the same timestamp; `id` breaks the tie so the ordering — and
/// therefore the pagination — stays total and stable.
///
/// `createdAt` is the exact string PostgREST returned, not a re-formatted
/// `Date`. Reformatting through `ISO8601DateFormatter` rounds to
/// milliseconds, and a value like `.909561` rounds *up* to `.910` — making
/// the cursor greater than the row it came from, so that row satisfies
/// `created_at < cursor` against itself and is returned again forever.
/// Passing the original text straight back through as the filter value
/// round-trips byte-for-byte and sidesteps the whole class of bug.
struct FeedCursor: Equatable {
    let createdAt: String
    let id: UUID
}
