import Foundation

/// Who may see a post — the `post_visibility` enum in the schema, chosen when
/// the post is made and fixed from then on. A trigger refuses any later
/// change; deleting and reposting is how you change your mind, so a photo
/// someone already saw can never vanish from under them, and one they could
/// never see can never surface at an old position in their feed.
///
/// Raw values are the Postgres labels, which is what PostgREST sends and
/// expects.
enum PostVisibility: String, Codable, CaseIterable, Sendable {
    /// Anyone who follows the author.
    case followers

    /// Only people the author also follows back — "friends", in the app's
    /// vocabulary; `mutuals`, in the database's.
    case mutuals

    /// The tier a post gets unless the person picks otherwise. Mirrors the
    /// column default: a new account's audience is almost entirely one-way
    /// followers at first, so `mutuals` would hide its first posts from
    /// nearly everyone.
    static let `default`: PostVisibility = .followers

    /// What the compose screen and the feed call the tier.
    var title: String {
        switch self {
        case .followers: return "Followers"
        case .mutuals: return "Friends only"
        }
    }
}
