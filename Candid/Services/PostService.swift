import Foundation
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
    /// Uploads the image, then records the post.
    ///
    /// Order matters. Uploading first means a failure part-way leaves an unused
    /// object in storage but **no** row — a post is never written pointing at an
    /// image that does not exist. Inserting first would produce exactly that
    /// broken row whenever an upload failed.
    ///
    /// The unused object cannot currently be tidied up from the client: storage
    /// has no delete policy, by design. Rare, and a stray object is cheaper than
    /// a broken feed entry, but it is a slow leak worth revisiting if uploads
    /// ever fail often.
    func createPost(image: UIImage, caption: String) async throws {
        let client = try SupabaseService.shared.client()

        // Cheapest check first: refusing here costs nothing, whereas letting the
        // database's CHECK constraint refuse it would come after the image had
        // already been uploaded — an orphaned object for a long caption.
        let caption = Self.normalizedCaption(caption)
        try Self.validateCaption(caption)

        let userId: UUID
        do {
            userId = try await client.auth.session.user.id
        } catch {
            throw Self.mapSessionError(error)
        }

        let imagePath = try await StorageService().uploadPostImage(image, userId: userId)

        do {
            try await client
                .from("posts")
                .insert(
                    NewPost(
                        userId: userId,
                        imagePath: imagePath,
                        caption: caption
                    )
                )
                .execute()
        } catch {
            throw Self.mapPostError(error)
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

    /// A missing session — including one the server has revoked, which the SDK
    /// reports the same way — means not signed in. A session that merely failed
    /// to refresh, typically for want of a network, does not, and says so in
    /// its own words instead. See `ProfileService.mapSessionError`.
    static func mapSessionError(_ error: Error) -> PostError {
        if let authError = error as? AuthError, authError.errorCode == .sessionNotFound {
            return .notSignedIn
        }
        return .other(error.localizedDescription)
    }

    static func mapPostError(_ error: Error) -> PostError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(error.localizedDescription)
        }

        // 42501 is Postgres' insufficient_privilege, which is how an RLS
        // rejection arrives — it would mean the row's user_id did not match the
        // caller.
        if postgrestError.code == "42501"
            || postgrestError.message.lowercased().contains("row-level security") {
            return .notPermitted(postgrestError.message)
        }

        // PostgrestError is a plain Error, so localizedDescription would be
        // Foundation boilerplate. Use the server's message.
        return .other(postgrestError.message)
    }
}

/// The insert payload. Separate from any read model: writes set only these
/// three columns, and the database fills in id and created_at.
private struct NewPost: Encodable {
    let userId: UUID
    let imagePath: String
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case imagePath = "image_path"
        case caption
    }
}
