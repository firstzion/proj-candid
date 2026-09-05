import Foundation
import OSLog
import Supabase
import UIKit

enum PostError: LocalizedError {
    case noImageSelected
    case captionTooLong
    case notSignedIn
    case notPermitted(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noImageSelected:
            return "Choose a photo first."
        case .captionTooLong:
            return "Captions can be at most \(PostService.maxCaptionLength.formatted()) characters."
        case .notSignedIn:
            return "You're not signed in."
        case .notPermitted(let message):
            return "The server rejected that post: \(message)"
        case .other(let message):
            return message
        }
    }
}

struct PostService {
    let client: SupabaseClient
    private let imageCache: ImageCache

    /// The signed-in user's id, read fresh for every call.
    ///
    /// Defaults to the SDK session — `auth.session`, so an expired access
    /// token is refreshed before the request rather than failing under RLS.
    /// Tests inject a fixed id so the row a post produces can be pinned
    /// without a live session, the same arrangement as `FollowService`.
    private let currentUserID: @Sendable () async throws -> UUID

    init(client: SupabaseClient, imageCache: ImageCache, currentUserID: (@Sendable () async throws -> UUID)? = nil) {
        self.client = client
        self.imageCache = imageCache
        self.currentUserID = currentUserID ?? { try await client.auth.session.user.id }
    }

    /// Uploads the image, then records the post for `visibility`'s audience.
    ///
    /// Order matters. Uploading first means a failure part-way leaves an unused
    /// object in storage but **no** row — a post is never written pointing at an
    /// image that does not exist. Inserting first would produce exactly that
    /// broken row whenever an upload failed.
    ///
    /// When the insert does fail, the object just uploaded is removed again —
    /// best effort, since the insert failure is the error worth reporting and a
    /// leaked object is the lesser problem if the delete fails too. Before the
    /// storage delete policy existed this was a slow, permanent leak.
    ///
    /// `visibility` is final: the database refuses to change it afterwards
    /// (see `PostVisibility`), so there is no update counterpart to this.
    func createPost(image: UIImage, caption: String, visibility: PostVisibility = .default) async throws {
        // Cheapest check first: refusing here costs nothing, whereas letting the
        // database's CHECK constraint refuse it would come after the image had
        // already been uploaded — an orphaned object for a long caption.
        let caption = Self.normalizedCaption(caption)
        try Self.validateCaption(caption)

        let userId: UUID
        do {
            userId = try await currentUserID()
        } catch {
            throw Self.mapSessionError(error)
        }

        let imagePath = try await StorageService(client: client).uploadPostImage(image, userId: userId)

        do {
            try await client
                .from("posts")
                .insert(
                    NewPost(
                        userId: userId,
                        imagePath: imagePath,
                        caption: caption,
                        visibility: visibility
                    )
                )
                .execute()
        } catch {
            // No row points at the object just uploaded, so take it back.
            // Best effort: the insert failure is the error worth reporting,
            // and a leaked object is the lesser problem if this fails too.
            try? await StorageService(client: client).deletePostImage(at: imagePath)
            throw Self.mapPostError(error)
        }

        // What was just posted is what the feed will show next, and the image
        // is already here: seed the cache so the poster's own post appears
        // without a download. After the insert, so a failed post leaves
        // nothing behind here either.
        imageCache.store(image, for: imagePath)
    }

    /// Deletes the post: the row first, then its image.
    ///
    /// The order is forced by the storage delete policy, which refuses an
    /// object a `posts` row still references — so "object first" would fail
    /// loudly rather than leave a live post with a broken image. The row is
    /// deleted by `id` alone: the `posts` delete policy scopes the statement
    /// to the caller's own rows, so no `user_id` filter is needed and a
    /// wrong one here could never remove someone else's. A row that is
    /// already gone matches nothing, which is not an error.
    ///
    /// A failed image delete after a successful row delete is logged, not
    /// thrown: the post is already out of every feed, and with no row the
    /// object is readable only through its owner's own folder clause — a
    /// storage cost, not a privacy one. Reporting it as a failed delete would
    /// tell the person their post is still there when it isn't. Account
    /// deletion makes the same call.
    func deletePost(id: UUID, imagePath: String) async throws {
        do {
            try await client
                .from("posts")
                .delete()
                .eq("id", value: id)
                .execute()
        } catch {
            throw Self.mapPostError(error)
        }

        do {
            try await StorageService(client: client).deletePostImage(at: imagePath)
        } catch {
            Logger(subsystem: "com.firstzion.candid", category: "PostService")
                .error("Post \(id.uuidString, privacy: .public) is deleted but its image \(imagePath, privacy: .public) could not be removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Blank and whitespace-only captions are stored as SQL NULL rather than an
    /// empty string, so "no caption" has one representation instead of two.
    static func normalizedCaption(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The most characters a caption may hold — the `posts_caption_length`
    /// CHECK in the schema, mirrored here so the refusal is a sentence rather
    /// than a constraint name, and happens before the upload.
    static let maxCaptionLength = 2200

    /// Measures in Unicode scalars because that is what Postgres' `char_length`
    /// counts: a flag emoji is one `Character` to Swift and two to the CHECK.
    static func validateCaption(_ caption: String?) throws {
        if let caption, caption.unicodeScalars.count > maxCaptionLength {
            throw PostError.captionTooLong
        }
    }

    static func mapSessionError(_ error: Error) -> PostError {
        SessionFailure.isMissingSession(error) ? .notSignedIn : .other(serverMessage(of: error))
    }

    static func mapPostError(_ error: Error) -> PostError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(serverMessage(of: error))
        }

        // 42501 is Postgres' insufficient_privilege, which is how an RLS
        // rejection arrives — it would mean the row's user_id did not match the
        // caller.
        if postgrestError.code == "42501"
            || postgrestError.message.lowercased().contains("row-level security") {
            return .notPermitted(postgrestError.message)
        }

        return .other(serverMessage(of: error))
    }
}

/// The insert payload. Separate from any read model: writes set only these
/// four columns, and the database fills in id and created_at. `visibility` is
/// always sent explicitly, even when it equals the column default, so the row
/// records the person's choice rather than whatever the default happens to be
/// on the day.
private struct NewPost: Encodable {
    let userId: UUID
    let imagePath: String
    let caption: String?
    let visibility: PostVisibility

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case imagePath = "image_path"
        case caption
        case visibility
    }
}
