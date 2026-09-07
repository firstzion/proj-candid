import Foundation

/// One `comments` row joined with its author's current username, plus the
/// two computed columns a comment row shows — its like count and whether the
/// signed-in user is among the likers (SOL-90, SOL-91). Like a post's
/// numbers these run under the caller's RLS, so a blocked pair's likes are
/// left out of each other's counts.
///
/// `var` on the like fields because `CommentsModel` flips them optimistically
/// in place; comment likes show on one screen, so they need no overlay.
struct Comment: Identifiable, Hashable, Sendable {
    let id: UUID
    let postID: UUID

    /// The commenter's `profiles.id` — what a tap on the name opens.
    let authorID: UUID
    let username: String
    let body: String
    let createdAt: Date
    var likeCount: Int
    var isLikedByViewer: Bool
}
