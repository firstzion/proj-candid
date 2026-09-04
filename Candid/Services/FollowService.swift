import Foundation
import Supabase

/// Errors surfaced by `FollowService`, worded for the button that caused them.
enum FollowError: LocalizedError {
    case notSignedIn
    case cannotTargetSelf
    case accountMissing
    case notPermitted
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .cannotTargetSelf:
            // The UI never offers either action on your own profile; this is
            // the wording for a request that arrived anyway.
            return "You can't follow or block yourself."
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
/// than stored anywhere, and blocks — the one relationship that overrides the
/// graph — in `blocks`. `ProfileScreen` is the UI over it (SOL-32, SOL-37).
///
/// Since SOL-66 a `follows` row is readable only at either end or by a mutual
/// of either end. Every read below asks for edges with the caller at one end,
/// so none of them noticed; the two public counts come from `counts(for:)`,
/// which calls a definer function rather than counting rows the policy hides.
///
/// Nothing here decides what a block *means*. The database severs follows
/// when a block is made, refuses a new follow across one, and (once the
/// `can_view_post()` rule lands) hides each side from the other; this type
/// only writes the row and reads back the caller's own.
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

    /// Blocks `userID`.
    ///
    /// The database does the rest, in the same transaction: a trigger severs
    /// the follow in both directions, and the `follows` insert policy refuses
    /// a new edge across the block in either direction until it is lifted. So
    /// nothing here unfollows first, and there is no client-side rule to keep
    /// in step. Blocking someone already blocked is not an error, for the same
    /// reason a duplicate follow isn't.
    ///
    /// Silent by design: `blocks` is readable only by the person who made the
    /// block, so nothing the other side can query changes.
    func block(_ userID: UUID) async throws {
        let me = try await sessionUserID()
        do {
            try await client
                .from("blocks")
                .insert(NewBlock(blockerID: me, blockedID: userID))
                .execute()
        } catch {
            if Self.isDuplicateEdge(error) { return }
            throw Self.mapFollowError(error)
        }
    }

    /// Lifts a block. Restores nothing: the follow edges the block severed
    /// stay severed, and either side may follow again from scratch. Idempotent
    /// for the same reason `unfollow` is.
    func unblock(_ userID: UUID) async throws {
        let me = try await sessionUserID()
        do {
            try await client
                .from("blocks")
                .delete()
                .eq("blocker_id", value: me)
                .eq("blocked_id", value: userID)
                .execute()
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// Whether the signed-in user has blocked `userID`. Only this direction
    /// can be asked: whether *they* have blocked *you* is deliberately not
    /// readable.
    func isBlocking(_ userID: UUID) async throws -> Bool {
        let me = try await sessionUserID()
        do {
            let rows = try await ownBlock(from: me, of: userID)
            return !rows.isEmpty
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// Both follow directions between the signed-in user and `userID` in one
    /// request — at most two rows — plus the caller's own block of them, so a
    /// profile can show "following", "follows you", "friends" or "blocked"
    /// without asking again. Asking about yourself is answered without a
    /// request: no edge or block can exist in either direction.
    func relationship(with userID: UUID) async throws -> Relationship {
        let me = try await sessionUserID()
        guard userID != me else { return .unconnected }
        do {
            let edges: [FollowEdge] = try await client
                .from("follows")
                .select("follower_id, followee_id")
                .or(Self.eitherDirectionFilter(me: me, other: userID))
                .execute()
                .value
            let blocks = try await ownBlock(from: me, of: userID)
            return Self.relationship(me: me, other: userID, edges: edges, blocking: !blocks.isEmpty)
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// Follower and following counts for `profileID`, from the
    /// `follow_counts` function — one row of two numbers.
    ///
    /// The numbers are public by decision (SOL-43); the lists behind them
    /// are not (SOL-66): a `follows` row is readable only at either end or
    /// by a mutual of either end, so a `count(*)` on the table from here
    /// would count only what the caller may see. The function runs as its
    /// definer and counts every row, which is why a stranger reads "3
    /// followers" on a profile without being able to read who.
    func counts(for profileID: UUID) async throws -> FollowCounts {
        do {
            return try await client
                .rpc("follow_counts", params: ["p_profile": profileID])
                .single()
                .execute()
                .value
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// The people who follow `profileID`, newest follow first: `follows` rows
    /// joined with the profile at the follower end. Who may read them is the
    /// database's call, not this method's — since SOL-66 an edge is readable
    /// only at either end or by a mutual of either end, so from any other
    /// seat this returns nothing. The profile screen only offers the list
    /// where it can be read; RLS is what enforces it.
    func followers(of profileID: UUID) async throws -> [Profile] {
        try await people(
            select: "profile:profiles!follows_follower_id_fkey(id,username)",
            where: "followee_id", equals: profileID
        )
    }

    /// The people `profileID` follows, newest follow first. Same rule as
    /// `followers(of:)`.
    func following(of profileID: UUID) async throws -> [Profile] {
        try await people(
            select: "profile:profiles!follows_followee_id_fkey(id,username)",
            where: "follower_id", equals: profileID
        )
    }

    /// One request: the edges matching `column = profileID`, each embedding
    /// the profile at the other end under the alias `profile`. An embedded
    /// profile the caller may not read comes back null — its owner has
    /// blocked them — and is dropped rather than shown blank.
    private func people(select: String, where column: String, equals profileID: UUID) async throws -> [Profile] {
        do {
            let rows: [FollowListRow] = try await client
                .from("follows")
                .select(select)
                .eq(column, value: profileID)
                .order("created_at", ascending: false)
                .execute()
                .value
            return rows.compactMap(\.profile)
        } catch {
            throw Self.mapFollowError(error)
        }
    }

    /// The caller's own `blocks` row for `userID`, if any — the select policy
    /// would hide anyone else's regardless of filter.
    private func ownBlock(from me: UUID, of userID: UUID) async throws -> [BlockRow] {
        try await client
            .from("blocks")
            .select("blocked_id")
            .eq("blocker_id", value: me)
            .eq("blocked_id", value: userID)
            .limit(1)
            .execute()
            .value
    }

    /// A PostgREST `or` filter matching the edge in either direction between
    /// two users. Exposed for the tests, which pin its shape.
    static func eitherDirectionFilter(me: UUID, other: UUID) -> String {
        "and(follower_id.eq.\(me.uuidString),followee_id.eq.\(other.uuidString)),"
            + "and(follower_id.eq.\(other.uuidString),followee_id.eq.\(me.uuidString))"
    }

    /// Derives the relationship from whatever edges came back. Pure, so the
    /// possible outcomes are pinned by tests without a request.
    static func relationship(me: UUID, other: UUID, edges: [FollowEdge], blocking: Bool = false) -> Relationship {
        Relationship(
            following: edges.contains { $0.followerID == me && $0.followeeID == other },
            followedBy: edges.contains { $0.followerID == other && $0.followeeID == me },
            blocking: blocking
        )
    }

    private func sessionUserID() async throws -> UUID {
        do {
            return try await currentUserID()
        } catch {
            throw Self.mapSessionError(error)
        }
    }

    /// Postgres `unique_violation` — a composite primary key refusing a second
    /// identical edge or block.
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
            // check_violation. follows_no_self_follow and blocks_no_self_block
            // are the only CHECK constraints on the graph tables, and both
            // say the same thing.
            return .cannotTargetSelf
        case "23503":
            // foreign_key_violation: the other account's profile is gone.
            return .accountMissing
        case "42501":
            // insufficient_privilege is how an RLS refusal arrives — since
            // SOL-31, including a follow attempted across a block.
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

/// One `follows` row as the lists read it: only the embedded profile at the
/// other end, nil when RLS hid it.
private struct FollowListRow: Decodable {
    let profile: Profile?
}

/// One `mutuals` row, of which only presence matters.
private struct MutualRow: Decodable {
    let mutualID: UUID

    enum CodingKeys: String, CodingKey {
        case mutualID = "mutual_id"
    }
}

/// The `blocks` insert payload: the two columns the client sets.
private struct NewBlock: Encodable {
    let blockerID: UUID
    let blockedID: UUID

    enum CodingKeys: String, CodingKey {
        case blockerID = "blocker_id"
        case blockedID = "blocked_id"
    }
}

/// One `blocks` row, of which only presence matters.
private struct BlockRow: Decodable {
    let blockedID: UUID

    enum CodingKeys: String, CodingKey {
        case blockedID = "blocked_id"
    }
}
