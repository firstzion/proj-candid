import Foundation
import Testing
import Supabase
@testable import Candid

/// `CommentService` (SOL-90) against canned PostgREST responses, stubbed at
/// the `URLProtocol` level like `FollowServiceTests`. Pinned: the thread
/// request (order, cap, the computed columns the select has to name), the
/// insert that reads its own row back, the by-`id`-only delete, the body
/// rules that refuse before any request, and the refusal that stays vague.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@Suite
struct CommentServiceTests {
    /// Fixed ids matching the seed's carol and alice, so a failure reads the
    /// same way here as it would against seeded data.
    private static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private static let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let post = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!

    private static func makeService() -> (CommentService, TestSupabaseClient.StubbedClient) {
        let stub = TestSupabaseClient.make()
        return (CommentService(client: stub.client, currentUserID: { Self.me }), stub)
    }

    /// One thread row as PostgREST returns it: lower-case uuids, the two
    /// computed columns, and the author embedded as an object — or `null`
    /// when RLS hid the profile.
    private static func rowJSON(
        id: UUID,
        author: UUID,
        username: String?,
        body: String,
        createdAt: String,
        likes: Int,
        liked: Bool
    ) -> String {
        let profiles = username.map { #"{"username":"\#($0)"}"# } ?? "null"
        return #"{"id":"\#(id.uuidString.lowercased())","post_id":"\#(Self.post.uuidString.lowercased())","user_id":"\#(author.uuidString.lowercased())","body":"\#(body)","created_at":"\#(createdAt)","comment_like_count":\#(likes),"comment_liked_by_viewer":\#(liked),"profiles":\#(profiles)}"#
    }

    @Test("comments(for:) asks for the thread oldest-first, capped, naming the computed columns, and decodes it")
    func threadRequestAndDecoding() async throws {
        let (service, stub) = Self.makeService()
        let first = UUID()
        let hidden = UUID()
        let second = UUID()
        let rows = [
            Self.rowJSON(id: first, author: Self.me, username: "carol", body: "Love this one", createdAt: "2026-09-04T14:04:30.909561+00:00", likes: 2, liked: false),
            // An author RLS hid: dropped, not shown blank, and not fatal.
            Self.rowJSON(id: hidden, author: UUID(), username: nil, body: "gone", createdAt: "2026-09-04T14:05:30.000000+00:00", likes: 0, liked: false),
            Self.rowJSON(id: second, author: Self.alice, username: "alice", body: "Thanks!", createdAt: "2026-09-04T15:04:30.000000+00:00", likes: 1, liked: true),
        ]
        stub.setHandler { _ in .init(body: Data("[\(rows.joined(separator: ","))]".utf8)) }

        let comments = try await service.comments(for: Self.post)

        #expect(comments.map(\.id) == [first, second])
        #expect(comments[0].username == "carol")
        #expect(comments[0].authorID == Self.me)
        #expect(comments[0].postID == Self.post)
        #expect(comments[0].body == "Love this one")
        #expect(comments[0].likeCount == 2)
        #expect(comments[0].isLikedByViewer == false)
        #expect(comments[1].username == "alice")
        #expect(comments[1].likeCount == 1)
        #expect(comments[1].isLikedByViewer)

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/comments")
        let query = request.queryParameters
        #expect(query["post_id"] == "eq.\(Self.post.uuidString)")
        #expect(query["order"]?.hasPrefix("created_at.asc") == true)
        #expect(query["order"]?.contains("id.asc") == true)
        #expect(query["limit"] == "\(CommentService.maxThreadLength)")
        // Computed columns are never part of `*`; a select that forgot them
        // would decode nothing.
        #expect(query["select"]?.contains("comment_like_count") == true)
        #expect(query["select"]?.contains("comment_liked_by_viewer") == true)
        #expect(query["select"]?.contains("profiles(username)") == true)
    }

    @Test("add sends the trimmed body as the caller and returns the row the server hands back")
    func addSendsAndDecodes() async throws {
        let (service, stub) = Self.makeService()
        let id = UUID()
        stub.setHandler { _ in
            .init(
                statusCode: 201,
                body: Data(Self.rowJSON(id: id, author: Self.me, username: "carol", body: "Love this one", createdAt: "2026-09-04T14:04:30.909561+00:00", likes: 0, liked: false).utf8)
            )
        }

        let comment = try await service.add("  Love this one \n", to: Self.post)

        #expect(comment.id == id)
        #expect(comment.body == "Love this one")
        #expect(comment.username == "carol")
        #expect(comment.likeCount == 0)
        #expect(comment.isLikedByViewer == false)

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/comments")
        // The row comes back in the same request, as one object.
        #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("return=representation") == true)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.pgrst.object+json")
        #expect(request.queryParameters["select"]?.contains("comment_like_count") == true)

        struct Body: Decodable {
            let postID: UUID
            let userID: UUID
            let body: String
            enum CodingKeys: String, CodingKey {
                case postID = "post_id"
                case userID = "user_id"
                case body
            }
        }
        let body = try JSONDecoder().decode(Body.self, from: try #require(request.drainedBody))
        #expect(body.postID == Self.post)
        #expect(body.userID == Self.me)
        #expect(body.body == "Love this one")
        #expect(stub.requests.count == 1)
    }

    /// The two refusals the app can make on its own happen before the session
    /// is asked for, so a blank or over-long draft costs no request at all.
    @Test("a blank or over-long body is refused before any request")
    func bodyRefusedBeforeRequest() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in .init(statusCode: 500, body: Data()) }

        do {
            _ = try await service.add(" \n\t ", to: Self.post)
            Issue.record("expected a blank body to throw")
        } catch let error as CommentError {
            guard case .empty = error else {
                Issue.record("expected .empty, got \(error)")
                return
            }
            #expect(error.localizedDescription == "Write something first.")
        }

        do {
            _ = try await service.add(String(repeating: "x", count: CommentService.maxBodyLength + 1), to: Self.post)
            Issue.record("expected an over-long body to throw")
        } catch let error as CommentError {
            guard case .tooLong = error else {
                Issue.record("expected .tooLong, got \(error)")
                return
            }
            #expect(error.localizedDescription == "Comments can be at most 1,000 characters.")
        }

        #expect(stub.requests.isEmpty)
    }

    /// Measured in unicode scalars, which is what Postgres' `char_length`
    /// counts: a flag emoji is one `Character` to Swift and two to the CHECK.
    @Test("preparedBody trims and measures the way char_length does")
    func preparedBody() throws {
        let trimmed = try CommentService.preparedBody("  hi there \n")
        #expect(trimmed == "hi there")

        let atLimit = String(repeating: "x", count: CommentService.maxBodyLength)
        let accepted = try CommentService.preparedBody(atLimit)
        #expect(accepted == atLimit)

        let flag = "\u{1F1E8}\u{1F1E6}"
        #expect(flag.count == 1)
        #expect(flag.unicodeScalars.count == 2)
        let flags = try CommentService.preparedBody(String(repeating: flag, count: CommentService.maxBodyLength / 2))
        #expect(flags.unicodeScalars.count == CommentService.maxBodyLength)
        #expect(throws: CommentError.self) {
            try CommentService.preparedBody(String(repeating: flag, count: CommentService.maxBodyLength / 2 + 1))
        }
    }

    @Test("delete sends the id and nothing else — whose it may be is the policy's call")
    func deleteByIDOnly() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in .init(statusCode: 204, body: Data()) }
        let id = UUID()

        try await service.delete(id)

        let request = try #require(stub.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/rest/v1/comments")
        let query = request.queryParameters
        #expect(query["id"] == "eq.\(id.uuidString)")
        #expect(query["user_id"] == nil)
        #expect(query["post_id"] == nil)
    }

    /// The insert policy refuses a post the caller cannot see — deleted, or
    /// hidden by a block since the thread opened — and the wording must not
    /// say which.
    @Test("a policy refusal is worded without saying why")
    func policyRefusalStaysVague() async throws {
        let (service, stub) = Self.makeService()
        stub.setHandler { _ in
            .init(
                statusCode: 403,
                body: Data(#"{"code":"42501","message":"new row violates row-level security policy for table \"comments\""}"#.utf8)
            )
        }

        do {
            _ = try await service.add("hello", to: Self.post)
            Issue.record("expected add to throw")
        } catch let error as CommentError {
            guard case .notPermitted = error else {
                Issue.record("expected .notPermitted, got \(error)")
                return
            }
            #expect(error.localizedDescription == "Couldn't post that comment right now.")
        }
    }
}
