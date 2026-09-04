import Foundation

/// Marks the feed stale outside its normal time-based check, so a just-posted
/// photo shows up without a pull-to-refresh.
///
/// `FeedView`'s own staleness check exists for signed-URL expiry, not for the
/// user's own writes — posting doesn't touch `loadedAt`, so a fresh feed
/// would otherwise sit unchanged until the half-hour mark. `PostView` bumps
/// `version` after a successful post; `FeedView` observes it via
/// `.onChange(of:)` and refreshes regardless of how stale it actually is.
@Observable
final class FeedInvalidation {
    private(set) var version = 0

    func markStale() {
        version += 1
    }
}
