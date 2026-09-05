import Foundation
import Testing
import Supabase
@testable import Candid

/// `ProfileService.profile(username:)` against canned PostgREST responses.
/// The lookup is how a person reaches someone they don't yet follow, so what
/// is pinned is that it asks `resolve_username` for exactly the normalised
/// name — so a former handle still finds its owner (SOL-41) — and treats "no
/// row" as nil rather than an error: the answer a typo, a stranger's name and
/// someone who has blocked you must all share.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@Suite
struct ProfileServiceRequestTests {
    private static let aliceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test("the lookup asks resolve_username for the normalised name and decodes the one row")
    func lookupFindsProfile() async throws {
        let stub = TestSupabaseClient.make()
        stub.setHandler { _ in
            .init(body: Data(#"[{"id":"\#(Self.aliceID.uuidString.lowercased())","username":"alice"}]"#.utf8))
        }

        let profile = try await ProfileService(client: stub.client).profile(username: "  Alice ")
        #expect(profile == Profile(id: Self.aliceID, username: "alice"))

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/rpc/resolve_username")
        struct Params: Decodable { let candidate: String }
        let params = try JSONDecoder().decode(Params.self, from: try #require(request.drainedBody))
        #expect(params.candidate == "alice")
    }

    @Test("no matching row is nil, not an error")
    func lookupMisses() async throws {
        let stub = TestSupabaseClient.make()
        stub.setHandler { _ in .init(body: Data("[]".utf8)) }

        let profile = try await ProfileService(client: stub.client).profile(username: "nobody")
        #expect(profile == nil)
    }

    /// The schema's CHECK would never have admitted such a name, so there is
    /// nothing to ask; and answering before any request keeps the wording
    /// identical to a miss.
    @Test("a name that cannot exist is answered nil without a request")
    func impossibleNameSkipsRequest() async throws {
        let stub = TestSupabaseClient.make()
        stub.setHandler { _ in .init(statusCode: 500, body: Data()) }

        let service = ProfileService(client: stub.client)
        for name in ["", "él", "ab", "alice smith"] {
            let profile = try await service.profile(username: name)
            #expect(profile == nil, "\(name) should be answered nil")
        }
        #expect(stub.requests.isEmpty)
    }
}

/// `ProfileService.postCount(for:)`: "posts you can see", not "posts". The
/// count is taken by the server under RLS — exact for the author, the
/// followers tier for a one-way follower, zero for a stranger — and the true
/// total is never sent to anyone else (SOL-37, SOL-40).
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@Suite
struct ProfileServicePostCountTests {
    private static let aliceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test("postCount asks the server to count one author's rows, with a HEAD request")
    func postCountIsAHeadRequest() async throws {
        let stub = TestSupabaseClient.make()
        stub.setHandler { _ in
            .init(statusCode: 200, body: Data(), headers: ["Content-Range": "0-1/2", "Content-Type": "application/json"])
        }

        let count = try await ProfileService(client: stub.client).postCount(for: Self.aliceID)
        #expect(count == 2)

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.path == "/rest/v1/posts")
        #expect(request.queryParameters["user_id"] == "eq.\(Self.aliceID.uuidString)")
        #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("count=exact") == true)
    }
}

/// `ProfileService.deleteAccount()`'s storage cleanup (SOL-74): every page is
/// listed at the same offset rather than an advancing one — removing a page
/// shifts what is left down, so an advancing offset skipped every other page
/// — and the loop stops the moment a listing comes back empty rather than
/// paging past the end.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@Suite
struct ProfileServiceDeleteAccountTests {
    private static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let listPath = "/storage/v1/object/list/post-images"
    private static let removePath = "/storage/v1/object/post-images"

    @Test("every object is removed regardless of count, with no list request carrying a non-zero offset")
    func removesAllObjectsWithoutAdvancingOffset() async throws {
        let stub = TestSupabaseClient.make()

        let folder = Self.me.uuidString.lowercased()
        let allNames = (0..<150).map { "photo\($0).jpg" }
        // 100, then 50, then an empty page — the shape a real folder with 150
        // objects has once each page is actually removed before the next is
        // listed, which is what the fix pages on rather than an offset.
        let pages = [Array(allNames[0..<100]), Array(allNames[100..<150]), []]
        let listCallIndex = Counter()

        stub.setHandler { request in
            switch request.url?.path {
            case "/rest/v1/rpc/delete_own_account":
                return .init(statusCode: 204, body: Data())
            case Self.listPath:
                let names = pages[min(listCallIndex.next(), pages.count - 1)]
                return .init(body: Self.fileObjects(named: names))
            case Self.removePath:
                struct RemoveBody: Decodable { let prefixes: [String] }
                let prefixes = (try? JSONDecoder().decode(RemoveBody.self, from: request.drainedBody ?? Data()).prefixes) ?? []
                let names = prefixes.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
                return .init(body: Self.fileObjects(named: names))
            default:
                return .init(statusCode: 404, body: Data())
            }
        }

        let service = ProfileService(client: stub.client, currentUserID: { Self.me })
        try await service.deleteAccount()

        struct ListBody: Decodable { let offset: Int? }
        let listRequests = stub.requests.filter { $0.url?.path == Self.listPath }
        #expect(listRequests.count == 3, "expected a list call per page plus the terminating empty one")
        for request in listRequests {
            let body = try JSONDecoder().decode(ListBody.self, from: try #require(request.drainedBody))
            #expect((body.offset ?? 0) == 0, "a list request carried a non-zero offset")
        }

        struct RemoveBody: Decodable { let prefixes: [String] }
        let removeRequests = stub.requests.filter { $0.url?.path == Self.removePath }
        let removedPaths = try removeRequests.flatMap { request in
            try JSONDecoder().decode(RemoveBody.self, from: try #require(request.drainedBody)).prefixes
        }
        #expect(Set(removedPaths) == Set(allNames.map { "\(folder)/\($0)" }))
    }

    /// A minimal `FileObject` array — just `name` and `id`, the only fields
    /// `removeAllStorageObjects` reads and the only ones that decode without
    /// pinning the SDK's date format.
    private static func fileObjects(named names: [String]) -> Data {
        let items = names.map { #"{"name":"\#($0)","id":"\#(UUID().uuidString)"}"# }.joined(separator: ",")
        return Data("[\(items)]".utf8)
    }
}

/// A thread-safe call counter for a stub handler that must answer
/// differently on successive calls — `StubURLProtocol`'s handler runs
/// wherever `URLSession` chooses, not necessarily the calling task.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}
