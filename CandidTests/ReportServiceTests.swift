import Foundation
import Testing
import Supabase
@testable import Candid

/// `ReportService` against canned PostgREST responses (SOL-42): the row each
/// kind of report writes, the repeat that is treated as success, and the
/// refusal that must stay vague. Who may report what is the insert policy's
/// business, not the client's.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@Suite
struct ReportServiceTests {
    private static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private static let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static func makeService() -> (ReportService, TestSupabaseClient.StubbedClient) {
        let stub = TestSupabaseClient.make()
        return (ReportService(client: stub.client, currentUserID: { Self.me }), stub)
    }

    private static func post() -> FeedPost {
        FeedPost(
            id: UUID(), authorID: alice, imagePath: "\(alice.uuidString.lowercased())/x.jpg", imageURL: nil,
            caption: nil, createdAt: .now, username: "alice", visibility: .followers,
            cursor: FeedCursor(createdAt: "2026-09-04T14:04:30.909561+00:00", id: UUID())
        )
    }

    private struct Row: Decodable {
        let reporter_id: UUID
        let reported_profile_id: UUID
        let reported_post_id: UUID?
        let reason: ReportReason
        let details: String?
    }

    @Test("reporting a post names the post and its author, with trimmed details")
    func postReport() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in .init(statusCode: 201, body: Data()) }

        let post = Self.post()
        try await service.report(post: post, reason: .harassment, details: "  not okay  ")

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/reports")
        let row = try JSONDecoder().decode(Row.self, from: try #require(request.drainedBody))
        #expect(row.reporter_id == Self.me)
        #expect(row.reported_profile_id == Self.alice)
        #expect(row.reported_post_id == post.id)
        #expect(row.reason == .harassment)
        #expect(row.details == "not okay")
    }

    @Test("reporting a person names no post, and blank details are left out")
    func profileReport() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in .init(statusCode: 201, body: Data()) }

        try await service.report(profile: Profile(id: Self.alice, username: "alice"), reason: .impersonation, details: "   ")

        let request = try #require(stub.requests.last)
        let body = try #require(request.drainedBody)
        let row = try JSONDecoder().decode(Row.self, from: body)
        #expect(row.reported_profile_id == Self.alice)
        #expect(row.reported_post_id == nil)
        #expect(row.reason == .impersonation)
        #expect(row.details == nil)
        let keys = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(keys["reported_post_id"] == nil)
        #expect(keys["details"] == nil)
    }

    @Test("a repeat report is success, not an error")
    func repeatIsSuccess() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in
            .init(statusCode: 409, body: Data(#"{"code":"23505","message":"duplicate key value violates unique constraint \"reports_one_per_post\""}"#.utf8))
        }
        try await service.report(post: Self.post(), reason: .spam, details: nil)
    }

    @Test("details over the limit are refused before any request")
    func detailsTooLong() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in .init(statusCode: 500, body: Data()) }

        await #expect(throws: ReportError.self) {
            try await service.report(post: Self.post(), reason: .other, details: String(repeating: "a", count: ReportService.maxDetailsLength + 1))
        }
        #expect(stub.requests.isEmpty)
    }

    /// The policy refuses a post the reporter cannot see; the wording must
    /// not say so, or the table becomes a way to probe post ids.
    @Test("an RLS refusal is reported without saying why")
    func refusalStaysVague() {
        let mapped = ReportService.mapReportError(
            PostgrestError(code: "42501", message: #"new row violates row-level security policy for table "reports""#)
        )
        guard case .notPermitted = mapped else {
            Issue.record("expected .notPermitted, got \(mapped)")
            return
        }
        let wording = mapped.errorDescription?.lowercased() ?? ""
        #expect(!wording.contains("policy") && !wording.contains("see") && !wording.contains("exist"))
    }
}
