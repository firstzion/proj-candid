import Foundation
import Testing
import Supabase
@testable import Candid

/// `FeedModel` (SOL-77) against canned PostgREST/Storage responses, the same
/// way `FeedServiceDecodingTests` and `PagedPostsTests` do. What is under
/// test is the logic that used to live only in `FeedView`: which of the two
/// empty states an empty feed decides on, and the optimistic delete that
/// reinserts on failure.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@MainActor
@Suite
struct FeedModelTests {
    private nonisolated static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private nonisolated static let author = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    /// `followingCount()` needs a signed-in id before it ever reaches the
    /// stub; a fixed one is injected the same way `FollowServiceTests` does,
    /// since `TestSupabaseClient` carries no real session.
    private static func makeModel() -> (FeedModel, TestSupabaseClient.StubbedClient) {
        let stub = TestSupabaseClient.make()
        let services = AppServices(client: stub.client, currentUserID: { Self.me })
        return (FeedModel(services: services), stub)
    }

    private static func stubEmptyPage(_ stub: TestSupabaseClient.StubbedClient, followingCount: Int?) {
        stub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/rest/v1/posts"):
                return .init(body: Data("[]".utf8))
            case ("HEAD", "/rest/v1/follows"):
                guard let followingCount else { return .init(statusCode: 400, body: Data()) }
                return .init(
                    statusCode: 200,
                    body: Data(),
                    headers: ["Content-Range": "0-\(max(followingCount - 1, 0))/\(followingCount)", "Content-Type": "application/json"]
                )
            default:
                return .init(statusCode: 404, body: Data())
            }
        }
    }

    @Test("an empty page with no one followed decides feedFollowingNobody")
    func emptyPageFollowingNobody() async throws {
        let (model, stub) = Self.makeModel()
        Self.stubEmptyPage(stub, followingCount: 0)

        await model.refresh()

        #expect(model.feedEmptyState == .feedFollowingNobody)
    }

    @Test("an empty page while following people decides feedNothingYet")
    func emptyPageFollowingSomeone() async throws {
        let (model, stub) = Self.makeModel()
        Self.stubEmptyPage(stub, followingCount: 3)

        await model.refresh()

        #expect(model.feedEmptyState == .feedNothingYet)
    }

    /// If the count itself fails, "nothing yet" is the safer wrong answer: it
    /// prompts nothing, rather than sending someone to the People tab because
    /// a request happened to fail.
    @Test("an empty page decides feedNothingYet when the following count fails")
    func emptyPageCountFails() async throws {
        let (model, stub) = Self.makeModel()
        Self.stubEmptyPage(stub, followingCount: nil)

        await model.refresh()

        #expect(model.feedEmptyState == .feedNothingYet)
    }

    /// Two posts, newest first, with just enough fields for `FeedService` to
    /// decode them and for `signedURLs` to have something to answer for.
    private static func stubTwoPostPage(_ stub: TestSupabaseClient.StubbedClient, ids: (UUID, UUID)) {
        stub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/rest/v1/posts"):
                let rows = [ids.0, ids.1].map { id in
                    #"{"id":"\#(id.uuidString)","user_id":"\#(Self.author.uuidString)","image_path":"\#(id.uuidString).jpg","caption":null,"visibility":"followers","created_at":"2026-09-04T14:04:30.000000+00:00","profiles":{"username":"alice"}}"#
                }
                return .init(body: Data("[\(rows.joined(separator: ","))]".utf8))
            case let (_, path?) where path.contains("/storage/v1/object/sign/"):
                return .init(body: Data(#"[{"path":"x","signedURL":"/sign/fake","error":null}]"#.utf8))
            default:
                return .init(statusCode: 404, body: Data())
            }
        }
    }

    @Test("a failed delete reinserts the post at its original index")
    func deleteFailureReinsertsAtOriginalIndex() async throws {
        let (model, stub) = Self.makeModel()
        let firstID = UUID()
        let secondID = UUID()
        Self.stubTwoPostPage(stub, ids: (firstID, secondID))

        await model.refresh()
        let originalOrder = model.paged.posts.map(\.id)
        #expect(originalOrder == [firstID, secondID])

        let postToDelete = try #require(model.paged.posts.first { $0.id == firstID })
        stub.setHandler { _ in .init(statusCode: 403, body: Data(#"{"code":"42501","message":"insufficient_privilege"}"#.utf8)) }

        let error = await model.delete(postToDelete, feedInvalidation: FeedInvalidation())

        #expect(error != nil)
        #expect(model.paged.posts.map(\.id) == originalOrder)
    }

    @Test("a successful delete leaves the post removed and marks the feed stale")
    func deleteSuccessRemovesPost() async throws {
        let (model, stub) = Self.makeModel()
        let firstID = UUID()
        let secondID = UUID()
        Self.stubTwoPostPage(stub, ids: (firstID, secondID))

        await model.refresh()
        let postToDelete = try #require(model.paged.posts.first { $0.id == firstID })
        stub.setHandler { _ in .init(statusCode: 204, body: Data()) }
        let feedInvalidation = FeedInvalidation()

        let error = await model.delete(postToDelete, feedInvalidation: feedInvalidation)

        #expect(error == nil)
        #expect(model.paged.posts.map(\.id) == [secondID])
        #expect(feedInvalidation.version == 1)
    }
}
