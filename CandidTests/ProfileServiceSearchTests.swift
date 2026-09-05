import Foundation
import Testing
import Supabase
@testable import Candid

/// `ProfileService.search(prefix:limit:)` (SOL-39): the request to the
/// `searchable_profiles` view, and the inputs that are answered empty without
/// one. Who appears in the results is the view's and RLS's business, not the
/// client's, so the shape of the ask is what matters here.
///
/// `.serialized`: `StubURLProtocol`'s state is process-global.
@Suite(.serialized)
struct ProfileServiceSearchTests {
    private static let aliceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test("search asks the view for a prefix match on current names, normalised and capped")
    func searchRequest() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in
            .init(body: Data(#"[{"id":"\#(Self.aliceID.uuidString.lowercased())","username":"alice"}]"#.utf8))
        }

        let results = try await ProfileService(client: TestSupabaseClient.make()).search(prefix: " Al ")
        #expect(results == [Profile(id: Self.aliceID, username: "alice")])

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/searchable_profiles")
        let query = request.queryParameters
        #expect(query["username"] == "like.al%")
        #expect(query["limit"] == "20")
        #expect(query["order"]?.hasPrefix("username.asc") == true)
    }

    /// `_` is a LIKE wildcard; in a username it is a character.
    @Test("an underscore in the prefix means itself")
    func underscoreIsEscaped() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(body: Data("[]".utf8)) }

        _ = try await ProfileService(client: TestSupabaseClient.make()).search(prefix: "a_")

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.queryParameters["username"] == #"like.a\_%"#)
    }

    /// Too short to be a search, or containing something no username can
    /// hold: nothing could match, so nothing is asked.
    @Test("a short or impossible prefix is answered empty without a request")
    func shortOrImpossiblePrefix() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 500, body: Data()) }

        let service = ProfileService(client: TestSupabaseClient.make())
        for prefix in ["", "a", " A ", "él", "al ice", "al-"] {
            let results = try await service.search(prefix: prefix)
            #expect(results.isEmpty, "\(prefix) should be answered empty")
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }
}
