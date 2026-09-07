import Foundation
import Supabase

/// Errors surfaced by `LikeService`, worded for the heart that caused them.
enum LikeError: LocalizedError {
    case notSignedIn
    case notPermitted
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .notPermitted:
            // Deliberately vague. The insert policy refuses a post or a
            // comment the caller cannot see — one deleted, or hidden by a
            // block, since the page loaded — and the wording must not say
            // which, for the same reason `FollowError.notPermitted` doesn't.
            return "Couldn't like that right now."
        case .other(let message):
            return message
        }
    }
}

/// Likes on posts (SOL-89) and on comments (SOL-91): one row per like,
/// binary by primary key. Nothing here decides who may like what — the
/// insert policies call `can_view_post()` and `can_view_comment()` — and a
/// like that already exists is not an error, for the same reason a
/// duplicate follow isn't: the state asked for already holds, and a double
/// tap must not read as a failure.
struct LikeService {
    let client: SupabaseClient

    /// The signed-in user's id, read fresh for every call — `auth.session`,
    /// so an expired access token is refreshed before the request rather
    /// than failing under RLS. Tests inject a fixed id, as with every other
    /// service: a live session is the one thing the stub cannot stand in for.
    private let currentUserID: @Sendable () async throws -> UUID

    init(client: SupabaseClient, currentUserID: (@Sendable () async throws -> UUID)? = nil) {
        self.client = client
        self.currentUserID = currentUserID ?? { try await client.auth.session.user.id }
    }

    /// Likes `postID`. Liking a post you already liked is not an error.
    func like(post postID: UUID) async throws {
        let me = try await sessionUserID()
        do {
            try await client
                .from("likes")
                .insert(NewLike(postID: postID, userID: me))
                .execute()
        } catch {
            if Self.isDuplicate(error) { return }
            throw Self.mapLikeError(error)
        }
    }

    /// Removes the caller's like of `postID`. Deleting a like that isn't
    /// there matches no rows and is not an error; the delete policy scopes
    /// the statement to the caller's own rows regardless of the filter, so a
    /// wrong filter here could never remove someone else's.
    func unlike(post postID: UUID) async throws {
        let me = try await sessionUserID()
        do {
            try await client
                .from("likes")
                .delete()
                .eq("post_id", value: postID)
                .eq("user_id", value: me)
                .execute()
        } catch {
            throw Self.mapLikeError(error)
        }
    }

    /// Likes `commentID` (SOL-91). The insert policy resolves the comment to
    /// its post through `can_view_comment()`; a duplicate is success, as with
    /// a post.
    func like(comment commentID: UUID) async throws {
        let me = try await sessionUserID()
        do {
            try await client
                .from("comment_likes")
                .insert(NewCommentLike(commentID: commentID, userID: me))
                .execute()
        } catch {
            if Self.isDuplicate(error) { return }
            throw Self.mapLikeError(error)
        }
    }

    /// Removes the caller's like of `commentID`; idempotent, as with a post.
    func unlike(comment commentID: UUID) async throws {
        let me = try await sessionUserID()
        do {
            try await client
                .from("comment_likes")
                .delete()
                .eq("comment_id", value: commentID)
                .eq("user_id", value: me)
                .execute()
        } catch {
            throw Self.mapLikeError(error)
        }
    }

    /// Postgres `unique_violation` — a composite primary key refusing a
    /// second identical like.
    static func isDuplicate(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }

    static func mapLikeError(_ error: Error) -> LikeError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(fallbackMessage(for: error, context: "LikeService.mapLikeError"))
        }
        // 42501 is insufficient_privilege, which is how an RLS refusal
        // arrives: the post or comment is not one the caller may see.
        if postgrestError.code == "42501"
            || postgrestError.message.lowercased().contains("row-level security") {
            return .notPermitted
        }
        return .other(fallbackMessage(for: error, context: "LikeService.mapLikeError"))
    }

    private func sessionUserID() async throws -> UUID {
        do {
            return try await currentUserID()
        } catch {
            throw SessionFailure.isMissingSession(error)
                ? LikeError.notSignedIn
                : .other(fallbackMessage(for: error, context: "LikeService.sessionUserID"))
        }
    }
}

/// `fetch`-free by design: `EngagementStore` only ever needs to write.
extension LikeService: PostLiking {}

/// The `likes` insert payload: the two columns the client sets. `created_at`
/// is the database's — a column grant, not just a default (20260906120000).
private struct NewLike: Encodable {
    let postID: UUID
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
        case userID = "user_id"
    }
}

/// The `comment_likes` insert payload: the same two-column shape.
private struct NewCommentLike: Encodable {
    let commentID: UUID
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case commentID = "comment_id"
        case userID = "user_id"
    }
}
