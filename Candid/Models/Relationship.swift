import Foundation

/// Where the signed-in user and another user stand with each other, as read
/// from `follows` and the signed-in user's own rows in `blocks`.
///
/// Mutuality is derived here exactly as it is in the database: the `mutuals`
/// view is a self-join on `follows`, and `isMutual` is the same join on the
/// two rows that matter. Nothing stores "friends" anywhere.
struct Relationship: Equatable, Sendable {
    /// The signed-in user follows them.
    var following: Bool

    /// They follow the signed-in user.
    var followedBy: Bool

    /// The signed-in user has blocked them. Only this direction is knowable:
    /// whether they have blocked the signed-in user is deliberately not
    /// readable, because a block is silent to the person on the other side
    /// of it. Defaults to false so callers that only know about follows need
    /// not mention it.
    var blocking: Bool = false

    /// Both directions at once — "friends", in the product's vocabulary.
    var isMutual: Bool { following && followedBy }

    /// No edge in either direction. Not named `none`: a static `none` on a
    /// type is ambiguous with `Optional.none` wherever the value could be
    /// promoted to an optional, and `relationship == .none` would silently
    /// compare against nil.
    static let unconnected = Relationship(following: false, followedBy: false)
}
