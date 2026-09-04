import Foundation

/// The two numbers a profile shows, as `follow_counts(profile)` returns them.
///
/// Public by decision (SOL-43), unlike the lists behind them: since SOL-66 a
/// `follows` row is readable only by the people at either end of it or by a
/// mutual of either end, so these are computed by a `security definer`
/// function rather than counted from rows the caller could fetch — a
/// stranger sees "3 followers" without being able to see who.
struct FollowCounts: Decodable, Equatable, Sendable {
    let followers: Int
    let following: Int
}
