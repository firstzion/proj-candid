import Foundation
import Testing
import Supabase
@testable import Candid

/// `ProfileModel` (SOL-77) against canned PostgREST responses, the same way
/// `FollowServiceTests` and `PagedPostsTests` do. What is under test is the
/// logic that used to live only in `ProfileScreen` and so could never be
/// reached by a test: optimistic follow/block/unblock with rollback, and the
/// relationship summary.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@MainActor
@Suite
struct ProfileModelTests {
    private nonisolated static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private nonisolated static let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private nonisolated static let otherProfile = Profile(id: other, username: "bob")

    private static func makeModel() -> (ProfileModel, TestSupabaseClient.StubbedClient) {
        let stub = TestSupabaseClient.make()
        let services = AppServices(client: stub.client, currentUserID: { Self.me })
        let model = ProfileModel(profile: Self.otherProfile, services: services, currentUserID: Self.me)
        return (model, stub)
    }

    /// Answers every request `load()` makes with an empty, unconnected
    /// relationship — the neutral starting point the follow/block tests build
    /// on top of.
    private static func stubUnconnectedLoad(_ stub: TestSupabaseClient.StubbedClient) {
        stub.setHandler { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/rest/v1/follows"), ("GET", "/rest/v1/blocks"), ("GET", "/rest/v1/posts"):
                return .init(body: Data("[]".utf8))
            case ("HEAD", "/rest/v1/posts"):
                return .init(statusCode: 200, body: Data(), headers: ["Content-Range": "0-0/0", "Content-Type": "application/json"])
            case ("POST", "/rest/v1/rpc/follow_counts"):
                return .init(body: Data(#"{"followers":0,"following":0}"#.utf8))
            default:
                return .init(statusCode: 404, body: Data())
            }
        }
    }

    @Test("toggleFollow updates the relationship on success and marks the feed stale")
    func toggleFollowSucceeds() async throws {
        let (model, stub) = Self.makeModel()
        Self.stubUnconnectedLoad(stub)
        await model.load()
        #expect(model.relationship == .unconnected)

        stub.setHandler { _ in .init(statusCode: 201, body: Data()) }
        let feedInvalidation = FeedInvalidation()

        await model.toggleFollow(feedInvalidation: feedInvalidation)

        #expect(model.relationship?.following == true)
        #expect(model.message == nil)
        #expect(feedInvalidation.version == 1)
    }

    /// The wording is deliberately vague (`FollowError.notPermitted`) — a
    /// block is silent to the person on the other side of it.
    @Test("toggleFollow rolls back to the previous relationship on failure")
    func toggleFollowRollsBackOnFailure() async throws {
        let (model, stub) = Self.makeModel()
        Self.stubUnconnectedLoad(stub)
        await model.load()
        let previous = try #require(model.relationship)

        stub.setHandler { request in
            request.httpMethod == "POST"
                ? .init(statusCode: 403, body: Data(#"{"code":"42501","message":"insufficient_privilege"}"#.utf8))
                : .init(statusCode: 404, body: Data())
        }

        await model.toggleFollow(feedInvalidation: FeedInvalidation())

        #expect(model.relationship == previous)
        #expect(model.message == .failure("Couldn't follow this account right now."))
    }

    @Test("block sets the blocking relationship immediately and rolls back on failure")
    func blockRollsBackOnFailure() async throws {
        let (model, stub) = Self.makeModel()
        Self.stubUnconnectedLoad(stub)
        await model.load()
        let previous = try #require(model.relationship)

        stub.setHandler { _ in .init(statusCode: 403, body: Data(#"{"code":"42501","message":"insufficient_privilege"}"#.utf8)) }
        await model.block(feedInvalidation: FeedInvalidation())
        #expect(model.relationship == previous)

        stub.setHandler { _ in .init(statusCode: 201, body: Data()) }
        let feedInvalidation = FeedInvalidation()
        await model.block(feedInvalidation: feedInvalidation)
        #expect(model.relationship == Relationship(following: false, followedBy: false, blocking: true))
        #expect(feedInvalidation.version == 1)
    }

    /// Unblocking restores nothing — no edge comes back — so the state after
    /// it is "not following", from scratch, regardless of what came before.
    @Test("unblock resets the relationship to unconnected")
    func unblockResetsRelationship() async throws {
        let (model, stub) = Self.makeModel()
        Self.stubUnconnectedLoad(stub)
        await model.load()

        stub.setHandler { _ in .init(statusCode: 201, body: Data()) }
        await model.block(feedInvalidation: FeedInvalidation())
        #expect(model.relationship?.blocking == true)

        stub.setHandler { _ in .init(statusCode: 204, body: Data()) }
        await model.unblock(feedInvalidation: FeedInvalidation())
        #expect(model.relationship == .unconnected)
    }

    @Test("summary(of:) covers the five relationship states")
    func summaryStates() {
        #expect(ProfileModel.summary(of: Relationship(following: false, followedBy: false, blocking: true)) == "Blocked")
        #expect(ProfileModel.summary(of: Relationship(following: true, followedBy: true)) == "Friends")
        #expect(ProfileModel.summary(of: Relationship(following: true, followedBy: false)) == "Following")
        #expect(ProfileModel.summary(of: Relationship(following: false, followedBy: true)) == "Follows you")
        #expect(ProfileModel.summary(of: .unconnected) == "Not following")
    }
}
