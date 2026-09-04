import Foundation

/// One post as shown in the feed: a `posts` row joined with its author's
/// `profiles.username`, carrying a ready-to-display signed URL for the image
/// rather than the raw storage path — see `StorageService`, which mints it.
struct FeedPost: Identifiable, Equatable {
    let id: UUID
    let imageURL: URL
    let caption: String?
    let createdAt: Date
    let username: String

    /// The cursor for fetching the page after this post — see
    /// `FeedService.fetchPosts(before:limit:)`. Carried as a stored property,
    /// set from the row's raw `created_at` text, rather than derived from
    /// `createdAt`: see `FeedCursor` for why re-deriving it is unsafe.
    let cursor: FeedCursor
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
