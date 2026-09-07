import Foundation

/// The three things a post card says about itself besides the photo: how
/// many people liked it, how many commented, and whether the signed-in user
/// is one of the likers (SOL-89). Read from the `post_like_count`,
/// `post_comment_count` and `post_liked_by_viewer` computed columns, which
/// run under the caller's own RLS — so, like the profile's post count, these
/// are "the likes you can see": a blocked pair's likes are left out of each
/// other's numbers (SOL-88).
///
/// `var` fields because `EngagementStore` derives an optimistic copy from
/// the row's value and shows that until the server's next word.
struct PostEngagement: Hashable, Sendable {
    var likeCount: Int
    var commentCount: Int
    var isLikedByViewer: Bool
}
