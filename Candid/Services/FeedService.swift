import Foundation
import Supabase

enum FeedServiceError: LocalizedError {
    case other(String)

    var errorDescription: String? {
        switch self {
        case .other(let message):
            return message
        }
    }
}

struct FeedService {
    let client: SupabaseClient

    static let defaultLimit = 20

    /// Fetches one page of posts, newest first, each carrying its author's
    /// username and a ready-to-display signed image URL.
    ///
    /// Pass the previous page's last post's `cursor` as `before` to fetch the
    /// next page; omit it for the first page. The query asks for `limit + 1`
    /// rows and returns at most `limit`; whether the extra row came back is
    /// what makes `FeedPage.hasMore` exact rather than a guess from the page
    /// length. An empty `posts` table (or an exhausted cursor) returns an
    /// empty page rather than throwing.
    func fetchPosts(before cursor: FeedCursor? = nil, limit: Int = FeedService.defaultLimit) async throws -> FeedPage {
        do {
            var query = client
                .from("posts")
                .select("id, user_id, image_path, caption, visibility, created_at, profiles(username)")

            if let cursor {
                // Keyset pagination on (created_at, id) rather than
                // created_at alone: two posts can share a timestamp, and a
                // plain `created_at < cursor` would silently drop or repeat
                // whichever of them didn't make the previous page.
                let cursorFilter = "created_at.lt.\(cursor.createdAt),and(created_at.eq.\(cursor.createdAt),id.lt.\(cursor.id.uuidString))"
                query = query.or(cursorFilter)
            }

            let rows: [PostRow] = try await query
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(limit + 1)
                .execute()
                .value

            let hasMore = rows.count > limit
            let pageRows = rows.prefix(limit)

            guard !pageRows.isEmpty else { return FeedPage(posts: [], hasMore: false) }

            let signedURLs = try await StorageService(client: client).signedURLs(for: pageRows.map(\.imagePath))

            // A row whose image didn't come back (e.g. the object went
            // missing) keeps its place with a nil URL rather than being
            // dropped. Dropping it made the page shorter than the query said,
            // and the feed read a short page as the end of the feed — one
            // missing object hid every older post.
            let posts = pageRows.map { row in
                FeedPost(
                    id: row.id,
                    authorID: row.userID,
                    imagePath: row.imagePath,
                    imageURL: signedURLs[row.imagePath],
                    caption: row.caption,
                    createdAt: row.createdAt,
                    username: row.profiles.username,
                    visibility: row.visibility,
                    cursor: FeedCursor(createdAt: row.createdAtRaw, id: row.id)
                )
            }
            return FeedPage(posts: posts, hasMore: hasMore)
        } catch {
            throw Self.mapFeedError(error)
        }
    }

    static func mapFeedError(_ error: Error) -> FeedServiceError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(error.localizedDescription)
        }
        // PostgrestError does not conform to LocalizedError, so its
        // localizedDescription is generic Foundation boilerplate. Use the
        // server's own message.
        return .other(postgrestError.message)
    }
}

/// Decodes one row of `posts` joined with its author's username. `profiles`
/// comes back as a single embedded object rather than an array, because
/// `posts.user_id` is a many-to-one foreign key to `profiles.id`.
///
/// `created_at` is decoded twice — once as `Date` for display, once as the
/// raw `String` for `FeedCursor` — because only the untouched original text
/// round-trips exactly into the next page's filter. See `FeedCursor`.
private struct PostRow: Decodable {
    let id: UUID
    let userID: UUID
    let imagePath: String
    let caption: String?
    let visibility: PostVisibility
    let createdAt: Date
    let createdAtRaw: String
    let profiles: ProfileUsername

    struct ProfileUsername: Decodable {
        let username: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case imagePath = "image_path"
        case caption
        case visibility
        case createdAt = "created_at"
        case profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userID = try container.decode(UUID.self, forKey: .userID)
        imagePath = try container.decode(String.self, forKey: .imagePath)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        visibility = try container.decode(PostVisibility.self, forKey: .visibility)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        createdAtRaw = try container.decode(String.self, forKey: .createdAt)
        profiles = try container.decode(ProfileUsername.self, forKey: .profiles)
    }
}
