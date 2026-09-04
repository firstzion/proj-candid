import Foundation
import Testing
import Supabase
@testable import Candid

/// `ProfileService.profile(username:)` against canned PostgREST responses.
/// The lookup is how a person reaches someone they don't yet follow, so what
/// is pinned is that it asks for exactly the normalised name and treats "no
/// row" as nil rather than an error — the answer a typo, a stranger's name
/// and someone who has blocked you must all share.
///
/// `.serialized`: `StubURLProtocol`'s state is process-global.
@Suite(.serialized)
struct ProfileServiceRequestTests {
    private static let aliceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test("the lookup asks for the normalised name and decodes the one row")
    func lookupFindsProfile() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        // `select()` is `*`, so the real response carries created_at too;
        // Profile must ignore what it doesn't decode.
        StubURLProtocol.setHandler { _ in
            .init(body: Data(#"[{"id":"\#(Self.aliceID.uuidString.lowercased())","username":"alice","created_at":"2026-09-04T14:04:30.909561+00:00"}]"#.utf8))
        }

        let profile = try await ProfileService(client: TestSupabaseClient.make()).profile(username: "  Alice ")
        #expect(profile == Profile(id: Self.aliceID, username: "alice"))

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/profiles")
        let query = request.queryParameters
        #expect(query["username"] == "eq.alice")
        #expect(query["limit"] == "1")
    }

    @Test("no matching row is nil, not an error")
    func lookupMisses() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(body: Data("[]".utf8)) }

        let profile = try await ProfileService(client: TestSupabaseClient.make()).profile(username: "nobody")
        #expect(profile == nil)
    }

    /// The schema's CHECK would never have admitted such a name, so there is
    /// nothing to ask; and answering before any request keeps the wording
    /// identical to a miss.
    @Test("a name that cannot exist is answered nil without a request")
    func impossibleNameSkipsRequest() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 500, body: Data()) }

        let service = ProfileService(client: TestSupabaseClient.make())
        for name in ["", "él", "ab", "alice smith"] {
            let profile = try await service.profile(username: name)
            #expect(profile == nil, "\(name) should be answered nil")
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }
}

/// `ProfileService.postCount(for:)`: "posts you can see", not "posts". The
/// count is taken by the server under RLS — exact for the author, the
/// followers tier for a one-way follower, zero for a stranger — and the true
/// total is never sent to anyone else (SOL-37, SOL-40).
///
/// `.serialized`: `StubURLProtocol`'s state is process-global.
@Suite(.serialized)
struct ProfileServicePostCountTests {
    private static let aliceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test("postCount asks the server to count one author's rows, with a HEAD request")
    func postCountIsAHeadRequest() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in
            .init(statusCode: 200, body: Data(), headers: ["Content-Range": "0-1/2", "Content-Type": "application/json"])
        }

        let count = try await ProfileService(client: TestSupabaseClient.make()).postCount(for: Self.aliceID)
        #expect(count == 2)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.path == "/rest/v1/posts")
        #expect(request.queryParameters["user_id"] == "eq.\(Self.aliceID.uuidString)")
        #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("count=exact") == true)
    }
}
