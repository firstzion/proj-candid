import Foundation
import Testing
import Supabase
@testable import Candid

/// `LikeService` against canned PostgREST responses, stubbed at the
/// `URLProtocol` level like `FollowServiceTests`. What is pinned is the
/// request each method builds — table, method, filters, body — because a
/// wrong filter here is silent (unliking nothing, or everything), and the
/// two refusals the service interprets: a duplicate that is success, and a
/// policy refusal that stays vague.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@Suite
struct LikeServiceTests {
    /// Fixed ids matching the seed's carol and one of alice's posts, so a
    /// failure reads the same way here as it would against seeded data.
    private static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private static let post = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!

    private static func makeService() -> (LikeService, TestSupabaseClient.StubbedClient) {
        let stub = TestSupabaseClient.make()
        return (LikeService(client: stub.client, currentUserID: { Self.me }), stub)
    }

    private struct LikeBody: Decodable {
        let postID: UUID
        let userID: UUID

        enum CodingKeys: String, CodingKey {
            case postID = "post_id"
            case userID = "user_id"
        }
    }

    @Test("like inserts the row with the caller as the liker, and sends nothing else")
    func likeInsertsRow() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in .init(statusCode: 201, body: Data()) }

        try await service.like(post: Self.post)

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/likes")

        let body = try JSONDecoder().decode(LikeBody.self, from: try #require(request.drainedBody))
        #expect(body.postID == Self.post)
        #expect(body.userID == Self.me)

        // One request: the count and the viewer's state come back with the
        // next page's computed columns, never from a read here.
        #expect(stub.requests.count == 1)
    }

    /// The composite primary key refuses a second identical like with a
    /// unique_violation. The state asked for already holds, so the service
    /// must treat it as success rather than surfacing a failure for a double
    /// tap or a stale heart.
    @Test("liking a post you already liked is not an error")
    func duplicateLikeIsSuccess() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in
            .init(
                statusCode: 409,
                body: Data(#"{"code":"23505","message":"duplicate key value violates unique constraint \"likes_pkey\""}"#.utf8)
            )
        }

        try await service.like(post: Self.post)
    }

    @Test("unlike deletes only the caller's own like of that post")
    func unlikeDeletesOwnRow() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in .init(statusCode: 204, body: Data()) }

        try await service.unlike(post: Self.post)

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/rest/v1/likes")

        let query = request.queryParameters
        #expect(query["post_id"] == "eq.\(Self.post.uuidString)")
        #expect(query["user_id"] == "eq.\(Self.me.uuidString)")
    }

    @Test("liking a comment inserts the row with the caller as the liker, and a duplicate is success")
    func likeCommentInsertsRow() async throws {
        let (service, stub) = Self.makeService()
        let comment = UUID()
        stub.setHandler { _ in .init(statusCode: 201, body: Data()) }

        try await service.like(comment: comment)

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/comment_likes")

        struct Body: Decodable {
            let commentID: UUID
            let userID: UUID
            enum CodingKeys: String, CodingKey {
                case commentID = "comment_id"
                case userID = "user_id"
            }
        }
        let body = try JSONDecoder().decode(Body.self, from: try #require(request.drainedBody))
        #expect(body.commentID == comment)
        #expect(body.userID == Self.me)

        stub.setHandler { _ in
            .init(
                statusCode: 409,
                body: Data(#"{"code":"23505","message":"duplicate key value violates unique constraint \"comment_likes_pkey\""}"#.utf8)
            )
        }
        try await service.like(comment: comment)
    }

    @Test("unliking a comment deletes only the caller's own like of it")
    func unlikeCommentDeletesOwnRow() async throws {
        let (service, stub) = Self.makeService()
        let comment = UUID()
        stub.setHandler { _ in .init(statusCode: 204, body: Data()) }

        try await service.unlike(comment: comment)

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/rest/v1/comment_likes")
        let query = request.queryParameters
        #expect(query["comment_id"] == "eq.\(comment.uuidString)")
        #expect(query["user_id"] == "eq.\(Self.me.uuidString)")
    }

    /// The insert policy refuses a post the caller cannot see — deleted, or
    /// hidden by a block since the page loaded — and the wording must not
    /// say which, since either would confirm something about a hidden post.
    @Test("a policy refusal is worded without saying why")
    func policyRefusalStaysVague() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in
            .init(
                statusCode: 403,
                body: Data(#"{"code":"42501","message":"new row violates row-level security policy for table \"likes\""}"#.utf8)
            )
        }

        do {
            try await service.like(post: Self.post)
            Issue.record("expected like to throw")
        } catch let error as LikeError {
            guard case .notPermitted = error else {
                Issue.record("expected .notPermitted, got \(error)")
                return
            }
            #expect(error.localizedDescription == "Couldn't like that right now.")
        }
    }
}
