import Foundation
import Supabase

/// Errors surfaced by `FollowService`, worded for the button that caused them.
enum FollowError: LocalizedError {
    case notSignedIn
    case cannotFollowSelf
    case accountMissing
    case notPermitted
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .cannotFollowSelf:
            return "You can't follow yourself."
        case .accountMissing:
            return "That account no longer exists."
        case .notPermitted:
            // Deliberately vague. Once blocking lands (SOL-31), the follows
            // insert policy refuses an edge across a block and the refusal
            // arrives here; the wording must not say why, because a block is
            // silent to the person on the other side of it.
            return "Couldn't follow this account right now."
        case .other(let message):
            return message
        }
    }
}

/// The follow graph from the signed-in user's point of view: one directional
/// edge per `follows` row, with "friends" derived by the `mutuals` view rather
/// than stored anywhere. Service layer only — the UI arrives with SOL-32.
struct FollowService {
    let client: SupabaseClient

    /// The signed-in user's id, read fresh for every call.
    ///
    /// Defaults to the SDK session — `auth.session`, so an expired access
    /// token is refreshed before the request rather than failing under RLS,
    /// the same as the other services. Tests inject a fixed id: a live
    /// session is the one thing `StubURLProtocol` cannot stand in for, and
    /// the shape of each request is what is worth pinning.
    private let currentUserID: @Sendable () async throws -> UUID

    init(client: SupabaseClient, currentUserID: (@Sendable () async throws -> UUID)? = nil) {
        self.client = client
        self.currentUserID = currentUserID ?? { try await client.auth.session.user.id }
    }

    /// Follows `userID`. Following someone you already follow is not an
    /// error: the state asked for already holds, and a double tap or a stale
    /// button must not read as a failure.
    func follow(_ userID: UUID) async throws {
        let me = try await sessionUserID()
        do {
            try await client
                .from("follows")
                .insert(NewFollow(followerID: me, followeeID: userID))
                .execute()
        } catch {
            if Self.isDuplicateEdge(error) { return }
            throw Self.mapFollowError(error)
        }
    }

    /// Unfollows `userID`. Deleting an edge that isn't there affects no rows
    /// and is not an error, so this is idempotent without any special case.
    /// The delete policy scopes the statement to the caller's own edges
    /// regardless of the filter, so a wrong filter here could never remove
    /// someone else's.
    func unfollow(_ userID: UUID) async throws {
        let me = try await sessionUserID()
        do {
            try await client
                .from("follows")
                .delete()
                .eq("follower_id", value: me)
                .eq("followee_id", value: userID)
                .execute()
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// Whether the signed-in user follows `userID`.
    func isFollowing(_ userID: UUID) async throws -> Bool {
        let me = try await sessionUserID()
        do {
            let rows: [FollowEdge] = try await client
                .from("follows")
                .select("follower_id, followee_id")
                .eq("follower_id", value: me)
                .eq("followee_id", value: userID)
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// Whether the signed-in user and `userID` follow each other — read from
    /// the `mutuals` view, the one definition of friendship, rather than
    /// re-deriving it here.
    func isMutual(_ userID: UUID) async throws -> Bool {
        let me = try await sessionUserID()
        do {
            let rows: [MutualRow] = try await client
                .from("mutuals")
                .select("mutual_id")
                .eq("user_id", value: me)
                .eq("mutual_id", value: userID)
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// Both directions between the signed-in user and `userID` in one
    /// request — at most two rows — so a profile can show "following",
    /// "follows you" or "friends" without asking twice. Asking about yourself
    /// is answered without a request: no edge can exist in either direction.
    func relationship(with userID: UUID) async throws -> Relationship {
        let me = try await sessionUserID()
        guard userID != me else { return .unconnected }
        do {
            let rows: [FollowEdge] = try await client
                .from("follows")
                .select("follower_id, followee_id")
                .or(Self.eitherDirectionFilter(me: me, other: userID))
                .execute()
                .value
            return Self.relationship(me: me, other: userID, edges: rows)
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// A PostgREST `or` filter matching the edge in either direction between
    /// two users. Exposed for the tests, which pin its shape.
    static func eitherDirectionFilter(me: UUID, other: UUID) -> String {
        "and(follower_id.eq.\(me.uuidString),followee_id.eq.\(other.uuidString)),"
            + "and(follower_id.eq.\(other.uuidString),followee_id.eq.\(me.uuidString))"
    }

    /// Derives the relationship from whatever edges came back. Pure, so the
    /// four possible outcomes are pinned by tests without a request.
    static func relationship(me: UUID, other: UUID, edges: [FollowEdge]) -> Relationship {
        Relationship(
            following: edges.contains { $0.followerID == me && $0.followeeID == other },
            followedBy: edges.contains { $0.followerID == other && $0.followeeID == me }
        )
    }

    private func sessionUserID() async throws -> UUID {
        do {
            return try await currentUserID()
        } catch {
            throw Self.mapSessionError(error)
        }
    }

    /// Postgres `unique_violation` — the composite primary key refusing a
    /// second identical edge.
    static func isDuplicateEdge(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }

    /// Same rule as the other services: only a genuinely missing session
    /// means not signed in. See `ProfileService.mapSessionError`.
    static func mapSessionError(_ error: Error) -> FollowError {
        if let authError = error as? AuthError, authError.errorCode == .sessionNotFound {
            return .notSignedIn
        }
        return .other(error.localizedDescription)
    }

    static func mapFollowError(_ error: Error) -> FollowError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(error.localizedDescription)
        }

        switch postgrestError.code ?? "" {
        case "23514":
            // check_violation. follows_no_self_follow is the table's only
            // CHECK constraint, so this can mean one thing.
            return .cannotFollowSelf
        case "23503":
            // foreign_key_violation: the followee's profile is gone.
            return .accountMissing
        case "42501":
            // insufficient_privilege is how an RLS refusal arrives.
            return .notPermitted
        default:
            if postgrestError.message.lowercased().contains("row-level security") {
                return .notPermitted
            }
            // PostgrestError is a plain Error, so localizedDescription would
            // be Foundation boilerplate. Use the server's message.
            return .other(postgrestError.message)
        }
    }
}

/// One `follows` row. Internal rather than private so the pure derivation
/// above can be tested with hand-built edges.
struct FollowEdge: Decodable, Equatable, Sendable {
    let followerID: UUID
    let followeeID: UUID

    enum CodingKeys: String, CodingKey {
        case followerID = "follower_id"
        case followeeID = "followee_id"
    }
}

/// The insert payload: the two columns the client sets. `created_at` is the
/// database's.
private struct NewFollow: Encodable {
    let followerID: UUID
    let followeeID: UUID

    enum CodingKeys: String, CodingKey {
        case followerID = "follower_id"
        case followeeID = "followee_id"
    }
}

/// One `mutuals` row, of which only presence matters.
private struct MutualRow: Decodable {
    let mutualID: UUID

    enum CodingKeys: String, CodingKey {
        case mutualID = "mutual_id"
    }
}
