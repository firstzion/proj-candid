import Foundation
import Testing
import Supabase
@testable import Candid

/// `FollowService` against canned PostgREST responses, stubbed at the
/// `URLProtocol` level like `FeedServiceDecodingTests`. What is pinned is the
/// *request* each method builds — table, HTTP method, filters, body — because
/// a wrong filter here is a silent bug (unfollowing nobody, or everybody) that
/// only a live project would otherwise reveal.
///
/// The signed-in user's id is injected, since a live session is the one thing
/// `StubURLProtocol` cannot stand in for.
///
/// `.serialized`: `StubURLProtocol`'s handler and recorded requests are
/// process-global.
@Suite(.serialized)
struct FollowServiceTests {
    /// Fixed ids matching the seed script's alice and bob, so a failure reads
    /// the same way here as it would against seeded data.
    private static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private static func makeService() -> FollowService {
        FollowService(client: TestSupabaseClient.make(), currentUserID: { Self.me })
    }

    @Test("follow inserts the edge with the caller as follower")
    func followInsertsEdge() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 201, body: Data()) }

        try await Self.makeService().follow(Self.other)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/follows")

        let body = try JSONDecoder().decode(FollowEdge.self, from: try #require(request.drainedBody))
        #expect(body.followerID == Self.me)
        #expect(body.followeeID == Self.other)
    }

    /// The composite primary key refuses a second identical edge with a
    /// unique_violation. The state asked for already holds, so the service
    /// must treat it as success rather than surfacing a failure for a double
    /// tap.
    @Test("following someone you already follow is not an error")
    func duplicateFollowIsSuccess() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in
            .init(
                statusCode: 409,
                body: Data(#"{"code":"23505","message":"duplicate key value violates unique constraint \"follows_pkey\""}"#.utf8)
            )
        }

        try await Self.makeService().follow(Self.other)
    }

    @Test("unfollow deletes only the caller's own edge to that user")
    func unfollowDeletesOwnEdge() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 204, body: Data()) }

        try await Self.makeService().unfollow(Self.other)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/rest/v1/follows")

        let query = Self.queryItems(of: request)
        #expect(query["follower_id"] == "eq.\(Self.me.uuidString)")
        #expect(query["followee_id"] == "eq.\(Self.other.uuidString)")
    }

    @Test("isFollowing asks for the one edge and reads its presence")
    func isFollowing() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let service = Self.makeService()

        StubURLProtocol.setHandler { _ in .init(body: Self.rowsJSON([(Self.me, Self.other)])) }
        let whenEdgeExists = try await service.isFollowing(Self.other)
        #expect(whenEdgeExists == true)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/follows")
        let query = Self.queryItems(of: request)
        #expect(query["follower_id"] == "eq.\(Self.me.uuidString)")
        #expect(query["followee_id"] == "eq.\(Self.other.uuidString)")
        #expect(query["limit"] == "1")

        StubURLProtocol.setHandler { _ in .init(body: Data("[]".utf8)) }
        let whenNoEdge = try await service.isFollowing(Self.other)
        #expect(whenNoEdge == false)
    }

    @Test("isMutual reads the mutuals view rather than re-deriving the join")
    func isMutualReadsTheView() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let service = Self.makeService()

        StubURLProtocol.setHandler { _ in
            .init(body: Data(#"[{"mutual_id":"\#(Self.other.uuidString)"}]"#.utf8))
        }
        let whenPairExists = try await service.isMutual(Self.other)
        #expect(whenPairExists == true)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.url?.path == "/rest/v1/mutuals")
        let query = Self.queryItems(of: request)
        #expect(query["user_id"] == "eq.\(Self.me.uuidString)")
        #expect(query["mutual_id"] == "eq.\(Self.other.uuidString)")

        StubURLProtocol.setHandler { _ in .init(body: Data("[]".utf8)) }
        let whenNoPair = try await service.isMutual(Self.other)
        #expect(whenNoPair == false)
    }

    @Test("relationship fetches both follow directions in one request and derives the state")
    func relationshipDerivesState() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let service = Self.makeService()

        let cases: [(edges: [(UUID, UUID)], expected: Relationship)] = [
            ([], .unconnected),
            ([(Self.me, Self.other)], Relationship(following: true, followedBy: false)),
            ([(Self.other, Self.me)], Relationship(following: false, followedBy: true)),
            ([(Self.me, Self.other), (Self.other, Self.me)], Relationship(following: true, followedBy: true)),
        ]

        for (edges, expected) in cases {
            let body = Self.rowsJSON(edges)
            StubURLProtocol.setHandler { request in
                // The follows request carries the edges; the blocks request
                // finds nothing.
                request.url?.path == "/rest/v1/blocks" ? .init(body: Data("[]".utf8)) : .init(body: body)
            }
            let relationship = try await service.relationship(with: Self.other)
            #expect(relationship == expected, "edges: \(edges)")
        }

        // Exactly two requests per call: follows, then the caller's own block.
        #expect(StubURLProtocol.requests.count == cases.count * 2)

        // The follows request asks for both directions at once, nothing else.
        let request = try #require(StubURLProtocol.requests.last { $0.url?.path == "/rest/v1/follows" })
        let filter = try #require(Self.queryItems(of: request)["or"])
        #expect(filter.contains("and(follower_id.eq.\(Self.me.uuidString),followee_id.eq.\(Self.other.uuidString))"))
        #expect(filter.contains("and(follower_id.eq.\(Self.other.uuidString),followee_id.eq.\(Self.me.uuidString))"))
    }

    @Test("relationship reads the caller's own block, and only that direction")
    func relationshipReadsOwnBlock() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }

        StubURLProtocol.setHandler { request in
            request.url?.path == "/rest/v1/blocks"
                ? .init(body: Data(#"[{"blocked_id":"\#(Self.other.uuidString.lowercased())"}]"#.utf8))
                : .init(body: Data("[]".utf8))
        }
        let relationship = try await Self.makeService().relationship(with: Self.other)
        #expect(relationship == Relationship(following: false, followedBy: false, blocking: true))

        // The blocks request can only ever ask about the caller's own row;
        // the select policy would hide anyone else's regardless.
        let request = try #require(StubURLProtocol.requests.last { $0.url?.path == "/rest/v1/blocks" })
        let query = Self.queryItems(of: request)
        #expect(query["blocker_id"] == "eq.\(Self.me.uuidString)")
        #expect(query["blocked_id"] == "eq.\(Self.other.uuidString)")
        #expect(query["limit"] == "1")
    }

    @Test("block inserts the row with the caller as blocker")
    func blockInsertsRow() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 201, body: Data()) }

        try await Self.makeService().block(Self.other)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/blocks")

        struct Body: Decodable {
            let blockerID: UUID
            let blockedID: UUID
            enum CodingKeys: String, CodingKey {
                case blockerID = "blocker_id"
                case blockedID = "blocked_id"
            }
        }
        let body = try JSONDecoder().decode(Body.self, from: try #require(request.drainedBody))
        #expect(body.blockerID == Self.me)
        #expect(body.blockedID == Self.other)

        // Nothing else is sent: severing the follows is the database's job.
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("blocking someone already blocked is not an error")
    func duplicateBlockIsSuccess() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in
            .init(
                statusCode: 409,
                body: Data(#"{"code":"23505","message":"duplicate key value violates unique constraint \"blocks_pkey\""}"#.utf8)
            )
        }

        try await Self.makeService().block(Self.other)
    }

    @Test("unblock deletes only the caller's own block of that user")
    func unblockDeletesOwnBlock() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 204, body: Data()) }

        try await Self.makeService().unblock(Self.other)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/rest/v1/blocks")
        let query = Self.queryItems(of: request)
        #expect(query["blocker_id"] == "eq.\(Self.me.uuidString)")
        #expect(query["blocked_id"] == "eq.\(Self.other.uuidString)")
        // And nothing touches follows: unblocking restores no edges.
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("isBlocking reads the caller's own block row and its presence")
    func isBlocking() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let service = Self.makeService()

        StubURLProtocol.setHandler { _ in
            .init(body: Data(#"[{"blocked_id":"\#(Self.other.uuidString.lowercased())"}]"#.utf8))
        }
        let whenBlocked = try await service.isBlocking(Self.other)
        #expect(whenBlocked == true)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.url?.path == "/rest/v1/blocks")
        let query = Self.queryItems(of: request)
        #expect(query["blocker_id"] == "eq.\(Self.me.uuidString)")
        #expect(query["blocked_id"] == "eq.\(Self.other.uuidString)")

        StubURLProtocol.setHandler { _ in .init(body: Data("[]".utf8)) }
        let whenNotBlocked = try await service.isBlocking(Self.other)
        #expect(whenNotBlocked == false)
    }

    /// No edge can exist between a user and themselves (the table's CHECK
    /// constraint), so there is nothing to ask the server.
    @Test("relationship with yourself is answered without a request")
    func relationshipWithSelf() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 500, body: Data()) }

        let relationship = try await Self.makeService().relationship(with: Self.me)
        #expect(relationship == .unconnected)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    /// Pinned separately from the request test: these four outcomes are the
    /// whole point of the type, and this is the one place they are derived.
    @Test("the relationship derivation reads edges in the right direction")
    func derivation() {
        let meToOther = FollowEdge(followerID: Self.me, followeeID: Self.other)
        let otherToMe = FollowEdge(followerID: Self.other, followeeID: Self.me)

        #expect(FollowService.relationship(me: Self.me, other: Self.other, edges: []) == .unconnected)
        #expect(FollowService.relationship(me: Self.me, other: Self.other, edges: [meToOther]).following)
        #expect(!FollowService.relationship(me: Self.me, other: Self.other, edges: [meToOther]).followedBy)
        #expect(FollowService.relationship(me: Self.me, other: Self.other, edges: [otherToMe]).followedBy)
        #expect(!FollowService.relationship(me: Self.me, other: Self.other, edges: [otherToMe]).following)
        #expect(FollowService.relationship(me: Self.me, other: Self.other, edges: [meToOther, otherToMe]).isMutual)
        #expect(FollowService.relationship(me: Self.me, other: Self.other, edges: [], blocking: true).blocking)
        #expect(!FollowService.relationship(me: Self.me, other: Self.other, edges: [meToOther]).blocking)
    }

    /// Public by decision, and computed by a definer function because the
    /// rows behind them are no longer readable to a non-mutual (SOL-66) — so
    /// the request has to be the RPC, never a count on the table.
    @Test("counts asks follow_counts for the one row of two numbers")
    func countsCallTheFunction() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(body: Data(#"{"followers":3,"following":1}"#.utf8)) }

        let counts = try await Self.makeService().counts(for: Self.other)
        #expect(counts == FollowCounts(followers: 3, following: 1))

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/rpc/follow_counts")
        // One object rather than a one-row array — what `.single()` asks
        // PostgREST for.
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.pgrst.object+json")

        struct Params: Decodable {
            let profile: UUID
            enum CodingKeys: String, CodingKey { case profile = "p_profile" }
        }
        let params = try JSONDecoder().decode(Params.self, from: try #require(request.drainedBody))
        #expect(params.profile == Self.other)
        // Nothing else is asked: the count is the function's, not a table read.
        #expect(StubURLProtocol.requests.count == 1)
    }

    /// Followers and following are `follows` rows joined with the profile at
    /// the other end, one request each; who may read them is RLS's call
    /// (SOL-66), not the client's. A follower whose profile is hidden from the
    /// caller comes back as a null embed and is dropped, not shown blank.
    @Test("followers and following read the edges joined with the right profile")
    func followLists() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let service = Self.makeService()
        StubURLProtocol.setHandler { _ in
            .init(body: Data(#"[{"profile":{"id":"\#(Self.other.uuidString.lowercased())","username":"bob"}},{"profile":null}]"#.utf8))
        }

        let followers = try await service.followers(of: Self.me)
        #expect(followers == [Profile(id: Self.other, username: "bob")])
        var request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/follows")
        var query = Self.queryItems(of: request)
        #expect(query["followee_id"] == "eq.\(Self.me.uuidString)")
        #expect(query["select"] == "profile:profiles!follows_follower_id_fkey(id,username)")

        let following = try await service.following(of: Self.me)
        #expect(following == [Profile(id: Self.other, username: "bob")])
        request = try #require(StubURLProtocol.requests.last)
        query = Self.queryItems(of: request)
        #expect(query["follower_id"] == "eq.\(Self.me.uuidString)")
        #expect(query["select"] == "profile:profiles!follows_followee_id_fkey(id,username)")
    }

    /// The feed's two empty states are told apart by this one number.
    @Test("followingCount asks the server to count the caller's own edges")
    func followingCount() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in
            .init(statusCode: 200, body: Data(), headers: ["Content-Range": "0-2/3", "Content-Type": "application/json"])
        }

        let count = try await Self.makeService().followingCount()
        #expect(count == 3)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.path == "/rest/v1/follows")
        #expect(Self.queryItems(of: request)["follower_id"] == "eq.\(Self.me.uuidString)")
        #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("count=exact") == true)
    }

    // MARK: - Fixtures

    private static func queryItems(of request: URLRequest) -> [String: String] {
        request.queryParameters
    }

    /// `follows` rows as PostgREST returns them — lower-case uuids, as
    /// Postgres renders them, to check decoding is case-insensitive.
    private static func rowsJSON(_ edges: [(UUID, UUID)]) -> Data {
        let rows = edges.map { follower, followee in
            #"{"follower_id":"\#(follower.uuidString.lowercased())","followee_id":"\#(followee.uuidString.lowercased())"}"#
        }
        return Data("[\(rows.joined(separator: ","))]".utf8)
    }
}
