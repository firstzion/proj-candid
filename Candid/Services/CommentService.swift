import Foundation
import Supabase

/// Errors surfaced by `CommentService`, worded for the composer.
enum CommentError: LocalizedError {
    case notSignedIn
    case empty
    case tooLong
    case notPermitted
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .empty:
            // The composer disables Send on a blank draft; this is the wording
            // for whitespace that slipped past it.
            return "Write something first."
        case .tooLong:
            return "Comments can be at most \(CommentService.maxBodyLength.formatted()) characters."
        case .notPermitted:
            // Deliberately vague, as with likes: the insert policy refused a
            // post the caller cannot see — deleted, or hidden by a block since
            // the thread opened — and saying which would confirm something
            // about a hidden post.
            return "Couldn't post that comment right now."
        case .other(let message):
            return message
        }
    }
}

/// Comments on a post (SOL-90): the thread, adding to it, and removing from
/// it. Nothing here decides who may read or write — the policies call
/// `can_view_post()` and the delete policy names the writer and the post's
/// author — and nothing here edits: comments are immutable, like posts.
struct CommentService {
    let client: SupabaseClient

    /// The signed-in user's id, read fresh for every write — `auth.session`,
    /// so an expired access token is refreshed before the request rather
    /// than failing under RLS. Tests inject a fixed id.
    private let currentUserID: @Sendable () async throws -> UUID

    init(client: SupabaseClient, currentUserID: (@Sendable () async throws -> UUID)? = nil) {
        self.client = client
        self.currentUserID = currentUserID ?? { try await client.auth.session.user.id }
    }

    /// The `comments_body_length` CHECK in the schema, mirrored so the
    /// refusal is a sentence and happens before the request. Measured in
    /// unicode scalars, which is what `char_length` counts.
    static let maxBodyLength = 1000

    /// One request loads a thread. A friends-only network does not produce
    /// threads longer than this, and a cap keeps one post from turning the
    /// screen into a download; paginating the thread is the follow-up if it
    /// ever binds (decided 2026-09-06).
    static let maxThreadLength = 500

    /// Every column a thread row needs, including the two computed columns —
    /// never part of `*`, so they are named — and the author's username.
    static let columns = "id, post_id, user_id, body, created_at, comment_like_count, comment_liked_by_viewer, profiles(username)"

    /// The thread, oldest first with `id` as the tiebreaker — the order the
    /// `comments_post_id_created_at_id_idx` index serves. RLS decides which
    /// rows exist for the caller; the query carries no filter of its own.
    func comments(for postID: UUID) async throws -> [Comment] {
        do {
            let rows: [CommentRow] = try await client
                .from("comments")
                .select(Self.columns)
                .eq("post_id", value: postID)
                .order("created_at", ascending: true)
                .order("id", ascending: true)
                .limit(Self.maxThreadLength)
                .execute()
                .value
            return rows.compactMap(Self.comment(from:))
        } catch {
            throw Self.mapCommentError(error)
        }
    }

    /// Posts `body` on `postID` and reads the row back in the same request
    /// (`Prefer: return=representation`), so the thread appends the server's
    /// own id, timestamp and zeroed like columns rather than inventing them.
    /// The body is validated first — before any request, and before the
    /// session is even asked for.
    func add(_ body: String, to postID: UUID) async throws -> Comment {
        let body = try Self.preparedBody(body)
        let me = try await sessionUserID()
        do {
            let row: CommentRow = try await client
                .from("comments")
                .insert(NewComment(postID: postID, userID: me, body: body))
                .select(Self.columns)
                .single()
                .execute()
                .value
            guard let comment = Self.comment(from: row) else {
                // The caller's own profile is always readable, so this cannot
                // happen; reported rather than crashed on, all the same.
                throw CommentError.other(fallbackMessage(
                    for: CommentServiceFailure.ownProfileMissing,
                    context: "CommentService.add"
                ))
            }
            return comment
        } catch {
            throw Self.mapCommentError(error)
        }
    }

    /// Deletes by `id` alone: the delete policy scopes the statement to what
    /// the caller may remove — their own comment, or any on their own post —
    /// so no `user_id` filter is needed, and a wrong one here could never
    /// widen it. A row that is already gone matches nothing, which is not an
    /// error.
    func delete(_ commentID: UUID) async throws {
        do {
            try await client
                .from("comments")
                .delete()
                .eq("id", value: commentID)
                .execute()
        } catch {
            throw Self.mapCommentError(error)
        }
    }

    /// Trimmed; a blank body refused; measured in unicode scalars because that
    /// is what Postgres' `char_length` counts — a flag emoji is one
    /// `Character` to Swift and two to the CHECK.
    static func preparedBody(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CommentError.empty }
        guard trimmed.unicodeScalars.count <= maxBodyLength else { throw CommentError.tooLong }
        return trimmed
    }

    static func mapCommentError(_ error: Error) -> CommentError {
        if let commentError = error as? CommentError { return commentError }
        guard let postgrestError = error as? PostgrestError else {
            return .other(fallbackMessage(for: error, context: "CommentService.mapCommentError"))
        }
        // 42501 is insufficient_privilege, which is how an RLS refusal
        // arrives: the post is not one the caller may see.
        if postgrestError.code == "42501"
            || postgrestError.message.lowercased().contains("row-level security") {
            return .notPermitted
        }
        return .other(fallbackMessage(for: error, context: "CommentService.mapCommentError"))
    }

    /// A thread row whose author could not be embedded is dropped rather than
    /// shown blank. The block-aware select policy means it cannot happen —
    /// the only profile hidden from a viewer is one whose owner blocked them,
    /// and that owner's comments are hidden too — and a whole thread failing
    /// to decode over one row would be the worse outcome if it ever did.
    private static func comment(from row: CommentRow) -> Comment? {
        guard let profile = row.profiles else { return nil }
        return Comment(
            id: row.id,
            postID: row.postID,
            authorID: row.userID,
            username: profile.username,
            body: row.body,
            createdAt: row.createdAt,
            likeCount: row.likeCount,
            isLikedByViewer: row.isLikedByViewer
        )
    }

    private func sessionUserID() async throws -> UUID {
        do {
            return try await currentUserID()
        } catch {
            throw SessionFailure.isMissingSession(error)
                ? CommentError.notSignedIn
                : .other(fallbackMessage(for: error, context: "CommentService.sessionUserID"))
        }
    }
}

/// The one failure `CommentService` can produce on its own, for the log.
private enum CommentServiceFailure: Error {
    case ownProfileMissing
}

/// Decodes one thread row: the comment, its two computed columns, and the
/// author embedded as a single object (`comments.user_id` is many-to-one to
/// `profiles.id`), nil when RLS hid it.
private struct CommentRow: Decodable {
    let id: UUID
    let postID: UUID
    let userID: UUID
    let body: String
    let createdAt: Date
    let likeCount: Int
    let isLikedByViewer: Bool
    let profiles: ProfileUsername?

    struct ProfileUsername: Decodable {
        let username: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case postID = "post_id"
        case userID = "user_id"
        case body
        case createdAt = "created_at"
        case likeCount = "comment_like_count"
        case isLikedByViewer = "comment_liked_by_viewer"
        case profiles
    }
}

/// The insert payload: the three columns the client sets. `id` and
/// `created_at` are the database's — column grants, not just defaults.
private struct NewComment: Encodable {
    let postID: UUID
    let userID: UUID
    let body: String

    enum CodingKeys: String, CodingKey {
        case postID = "post_id"
        case userID = "user_id"
        case body
    }
}
