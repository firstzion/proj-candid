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

    @Test("relationship fetches both directions in one request and derives the state")
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
            StubURLProtocol.setHandler { _ in .init(body: body) }
            let relationship = try await service.relationship(with: Self.other)
            #expect(relationship == expected, "edges: \(edges)")
        }

        #expect(StubURLProtocol.requests.count == cases.count)

        // One request, both directions, nothing else.
        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.url?.path == "/rest/v1/follows")
        let filter = try #require(Self.queryItems(of: request)["or"])
        #expect(filter.contains("and(follower_id.eq.\(Self.me.uuidString),followee_id.eq.\(Self.other.uuidString))"))
        #expect(filter.contains("and(follower_id.eq.\(Self.other.uuidString),followee_id.eq.\(Self.me.uuidString))"))
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
    }

    // MARK: - Fixtures

    /// The query string as PostgREST will read it — percent-decoded, so an
    /// `or=` filter's parentheses and commas compare as written.
    private static func queryItems(of request: URLRequest) -> [String: String] {
        guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
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
