import Foundation
import Testing
import Supabase
@testable import Candid

/// `FeedService.fetchPosts` and its private `PostRow` decoder carry the most
/// intricate logic in the app — see `FeedCursor`'s doc comment for the
/// rounding bug a byte-for-byte cursor sidesteps, and `FeedPage.hasMore`'s
/// for why the page size query asks for one extra row rather than trusting
/// `posts.count`. These tests pin both against real PostgREST/Storage
/// response shapes, stubbed at the `URLProtocol` level via a `FeedService`
/// built with dependency injection (SOL-47) — no live project required.
///
/// `.serialized`: `StubURLProtocol`'s handler and recorded requests are
/// process-global, so tests that install their own handler would stomp on
/// each other if Swift Testing ran them concurrently.
@Suite(.serialized)
struct FeedServiceDecodingTests {
    private struct Row {
        let id: UUID
        let imagePath: String
        let createdAt: String
        let username: String
    }

    @Test("fetchPosts decodes real PostgREST/Storage response shapes correctly")
    func fetchPostsDecoding() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }

        // Pins the cursor's exact-text requirement: six fractional digits
        // that ISO8601DateFormatter would round up to `.910`, corrupting a
        // re-derived cursor into matching its own row forever. See
        // FeedCursor's doc comment.
        let pinnedRow = Row(
            id: UUID(),
            imagePath: "\(UUID().uuidString)/\(UUID().uuidString).jpg",
            createdAt: "2026-09-04T14:04:30.909561+00:00",
            username: "alice"
        )

        // The path the sign endpoint below reports as unsigned, to check
        // that its post is kept with a nil URL rather than dropped.
        let unsignedPath = "\(UUID().uuidString)/\(UUID().uuidString).jpg"

        let page1Rows = [pinnedRow] + (1..<21).map { i in
            Row(
                id: UUID(),
                imagePath: i == 5 ? unsignedPath : "\(UUID().uuidString)/\(UUID().uuidString).jpg",
                createdAt: Self.timestamp(secondsBeforeBase: i),
                username: "user\(i)"
            )
        }
        let page2Rows = (21..<26).map { i in
            Row(
                id: UUID(),
                imagePath: "\(UUID().uuidString)/\(UUID().uuidString).jpg",
                createdAt: Self.timestamp(secondsBeforeBase: i),
                username: "user\(i)"
            )
        }

        StubURLProtocol.setHandler { request in
            guard let url = request.url else {
                return .init(statusCode: 400, body: Data())
            }

            if url.path.contains("/storage/v1/object/sign/") {
                return Self.signResponse(for: request, unsignedPath: unsignedPath)
            }

            // Second page's request carries the `or=` keyset filter; the
            // first page's does not.
            let isPage2 = url.query?.contains("or=") == true
            return .init(statusCode: 200, body: Self.rowsJSON(isPage2 ? page2Rows : page1Rows))
        }

        let feedService = FeedService(client: TestSupabaseClient.make())

        let page1 = try await feedService.fetchPosts()
        #expect(page1.posts.count == 20)
        #expect(page1.hasMore == true)

        // Byte-for-byte, not just equal-as-dates: this is what makes the
        // cursor safe to round-trip into the next page's filter.
        #expect(page1.posts[0].cursor.createdAt == pinnedRow.createdAt)
        #expect(page1.posts[0].id == pinnedRow.id)

        // The unsigned row (index 5) is kept, with no URL, rather than
        // dropped and silently shortening the page.
        let unsignedPost = try #require(page1.posts.first { $0.imagePath == unsignedPath })
        #expect(unsignedPost.imageURL == nil)

        // Every other row in this page did get a URL.
        let signedCount = page1.posts.filter { $0.imageURL != nil }.count
        #expect(signedCount == 19)

        let page2 = try await feedService.fetchPosts(before: page1.posts.last?.cursor)
        #expect(page2.posts.count == 5)
        #expect(page2.hasMore == false)

        // The `+` in `+00:00` must reach PostgREST as `%2B` — a literal `+`
        // in a URL query string means space, and would silently truncate the
        // cursor's timestamp.
        let paginatedRequest = try #require(
            StubURLProtocol.requests.last { $0.url?.query?.contains("or=") == true }
        )
        #expect(paginatedRequest.url?.absoluteString.contains("%2B") == true)
    }

    @Test("a PostgrestError body maps to FeedServiceError.other with the server's message")
    func postgrestErrorMapsThrough() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }

        let errorBody = Data(
            #"{"message":"permission denied for table posts","code":"42501"}"#.utf8
        )
        StubURLProtocol.setHandler { _ in .init(statusCode: 400, body: errorBody) }

        let feedService = FeedService(client: TestSupabaseClient.make())

        do {
            _ = try await feedService.fetchPosts()
            Issue.record("expected fetchPosts to throw")
        } catch let error as FeedServiceError {
            guard case .other(let message) = error else {
                Issue.record("expected .other, got \(error)")
                return
            }
            #expect(message == "permission denied for table posts")
        }
    }

    // MARK: - Fixtures

    /// A distinct, valid `timestamptz` string `index` seconds before a fixed
    /// base — real six-fractional-digit PostgREST formatting, just with
    /// zeroed-out microseconds since only the pinned row's exact digits are
    /// under test.
    private static func timestamp(secondsBeforeBase index: Int) -> String {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026
        components.month = 9
        components.day = 4
        components.hour = 14
        components.minute = 4
        components.second = 30
        let base = components.date!
        let date = base.addingTimeInterval(-Double(index))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func rowsJSON(_ rows: [Row]) -> Data {
        let body = rows.map { row in
            #"{"id":"\#(row.id.uuidString)","image_path":"\#(row.imagePath)","caption":null,"created_at":"\#(row.createdAt)","profiles":{"username":"\#(row.username)"}}"#
        }.joined(separator: ",")
        return Data("[\(body)]".utf8)
    }

    /// Mirrors `object/sign/<bucket>`'s real response shape: one entry per
    /// requested path, `unsignedPath` reported as a failure like a missing
    /// object would be, everything else a usable (if fake) signed URL.
    private static func signResponse(for request: URLRequest, unsignedPath: String) -> StubURLProtocol.Response {
        struct SignParams: Decodable { let paths: [String] }
        guard
            let body = request.drainedBody,
            let params = try? JSONDecoder().decode(SignParams.self, from: body)
        else {
            return .init(statusCode: 400, body: Data())
        }

        let entries = params.paths.map { path -> String in
            if path == unsignedPath {
                return #"{"path":"\#(path)","signedURL":null,"error":"Object not found"}"#
            }
            return #"{"path":"\#(path)","signedURL":"/sign/\#(UUID().uuidString)?token=fake","error":null}"#
        }
        return .init(statusCode: 200, body: Data("[\(entries.joined(separator: ","))]".utf8))
    }
}
