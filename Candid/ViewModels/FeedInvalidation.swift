import Foundation

/// Marks the feed stale outside its normal time-based check, so what the
/// person just did shows up without a pull-to-refresh.
///
/// `FeedView`'s own staleness check exists for signed-URL expiry, not for the
/// user's own writes — none of them touch `loadedAt`, so a fresh feed would
/// otherwise sit unchanged until the half-hour mark. `PostView` bumps
/// `version` after a successful post, `ProfileScreen` after a follow,
/// unfollow, block or unblock, and every Delete after a post is gone: each of
/// those changes which rows the database will hand back. `FeedView` and
/// `ProfileScreen` observe it via `.onChange(of:)` and refresh
/// regardless of how stale it actually is — from the newest page, replacing
/// the list, so rows that are no longer permitted disappear rather than
/// lingering until they scroll off. That blanket refresh is the whole
/// invalidation strategy (SOL-32); the README says what is deliberately not
/// invalidated, and why.
@Observable
final class FeedInvalidation {
    private(set) var version = 0

    func markStale() {
        version += 1
    }
}
