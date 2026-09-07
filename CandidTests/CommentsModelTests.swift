import Foundation
import Testing
import Supabase
@testable import Candid

/// `CommentsModel` (SOL-90) against canned PostgREST responses, the way
/// `FeedModelTests` drives `FeedModel`: the thread in server order, an add
/// that appends the returned row and moves the card's count through
/// `EngagementStore`, a delete that comes back on failure, and the delete
/// rule the menu mirrors.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@MainActor
@Suite
struct CommentsModelTests {
    private nonisolated static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private nonisolated static let alice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private nonisolated static let bob = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private static func post(by author: UUID, commentCount: Int = 2) -> FeedPost {
        let id = UUID()
        return FeedPost(
            id: id,
            authorID: author,
            imagePath: "\(author.uuidString.lowercased())/photo.jpg",
            imageURL: nil,
            caption: "Seed post 1",
            createdAt: Date(timeIntervalSince1970: 0),
            username: author == Self.me ? "carol" : "alice",
            visibility: .followers,
            engagement: PostEngagement(likeCount: 0, commentCount: commentCount, isLikedByViewer: false),
            cursor: FeedCursor(createdAt: "2026-09-04T14:04:30.909561+00:00", id: id)
        )
    }

    private static func comment(_ id: UUID = UUID(), by author: UUID, on post: FeedPost) -> Comment {
        Comment(
            id: id,
            postID: post.id,
            authorID: author,
            username: author == Self.me ? "carol" : "bob",
            body: "hello",
            createdAt: Date(timeIntervalSince1970: 0),
            likeCount: 0,
            isLikedByViewer: false
        )
    }

    private static func makeModel(post: FeedPost) -> (CommentsModel, TestSupabaseClient.StubbedClient) {
        let stub = TestSupabaseClient.make()
        let services = AppServices(client: stub.client, currentUserID: { Self.me })
        return (CommentsModel(post: post, services: services, currentUserID: Self.me), stub)
    }

    private static func rowJSON(id: UUID, author: UUID, username: String, body: String, at seconds: Int) -> String {
        #"{"id":"\#(id.uuidString.lowercased())","post_id":"\#(UUID().uuidString.lowercased())","user_id":"\#(author.uuidString.lowercased())","body":"\#(body)","created_at":"2026-09-04T14:04:\#(seconds).000000+00:00","comment_like_count":0,"comment_liked_by_viewer":false,"profiles":{"username":"\#(username)"}}"#
    }

    /// Answers the thread with `rows`, a POST with `posted`, and a DELETE with
    /// `deleteStatus`, so one handler serves a whole test.
    private static func stub(
        _ stub: TestSupabaseClient.StubbedClient,
        rows: [String],
        posted: String? = nil,
        deleteStatus: Int = 204
    ) {
        stub.setHandler { request in
            switch request.httpMethod {
            case "GET":
                return .init(body: Data("[\(rows.joined(separator: ","))]".utf8))
            case "POST":
                guard let posted else {
                    return .init(statusCode: 403, body: Data(#"{"code":"42501","message":"new row violates row-level security policy for table \"comments\""}"#.utf8))
                }
                return .init(statusCode: 201, body: Data(posted.utf8))
            case "DELETE":
                return .init(statusCode: deleteStatus, body: deleteStatus == 204 ? Data() : Data(#"{"code":"42501","message":"insufficient_privilege"}"#.utf8))
            default:
                return .init(statusCode: 404, body: Data())
            }
        }
    }

    @Test("load keeps the server's order")
    func loadKeepsOrder() async {
        let post = Self.post(by: Self.alice)
        let (model, stub) = Self.makeModel(post: post)
        let first = UUID()
        let second = UUID()
        Self.stub(stub, rows: [
            Self.rowJSON(id: first, author: Self.me, username: "carol", body: "Love this one", at: 30),
            Self.rowJSON(id: second, author: Self.alice, username: "alice", body: "Thanks!", at: 31),
        ])

        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.comments.map(\.id) == [first, second])
    }

    @Test("a failed load with nothing on screen is the failed phase")
    func loadFailure() async {
        let post = Self.post(by: Self.alice)
        let (model, stub) = Self.makeModel(post: post)
        stub.setHandler { _ in .init(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8)) }

        await model.load()

        guard case .failed = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(model.comments.isEmpty)
    }

    @Test("add appends the returned row and moves the card's count up")
    func addAppends() async {
        let post = Self.post(by: Self.alice, commentCount: 2)
        let (model, stub) = Self.makeModel(post: post)
        let newID = UUID()
        Self.stub(stub, rows: [], posted: Self.rowJSON(id: newID, author: Self.me, username: "carol", body: "First!", at: 40))
        await model.load()
        let store = EngagementStore()

        let added = await model.add("First!", engagement: store)

        #expect(added?.id == newID)
        #expect(model.comments.map(\.id) == [newID])
        #expect(model.message == nil)
        #expect(store.engagement(for: post).commentCount == 3)
    }

    @Test("a refused add appends nothing, says why, and leaves the count alone")
    func addFailure() async {
        let post = Self.post(by: Self.alice, commentCount: 2)
        let (model, stub) = Self.makeModel(post: post)
        Self.stub(stub, rows: [], posted: nil)
        await model.load()
        let store = EngagementStore()

        let added = await model.add("First!", engagement: store)

        #expect(added == nil)
        #expect(model.comments.isEmpty)
        #expect(model.message?.kind == .failure)
        #expect(store.engagement(for: post).commentCount == 2)

        // A blank draft is refused by the service before any request.
        stub.reset()
        let blank = await model.add("   ", engagement: store)
        #expect(blank == nil)
        #expect(model.message?.text == "Write something first.")
        #expect(stub.requests.isEmpty)
    }

    @Test("a failed delete puts the comment back where it was")
    func deleteFailureReinserts() async {
        let post = Self.post(by: Self.alice, commentCount: 2)
        let (model, stub) = Self.makeModel(post: post)
        let first = UUID()
        let second = UUID()
        Self.stub(stub, rows: [
            Self.rowJSON(id: first, author: Self.me, username: "carol", body: "one", at: 30),
            Self.rowJSON(id: second, author: Self.alice, username: "alice", body: "two", at: 31),
        ], deleteStatus: 403)
        await model.load()
        let store = EngagementStore()
        let mine = model.comments[0]

        await model.delete(mine, engagement: store)

        #expect(model.comments.map(\.id) == [first, second])
        #expect(model.message?.kind == .failure)
        #expect(store.engagement(for: post).commentCount == 2)
    }

    @Test("a successful delete leaves the comment removed and moves the count down")
    func deleteSuccess() async {
        let post = Self.post(by: Self.alice, commentCount: 2)
        let (model, stub) = Self.makeModel(post: post)
        let first = UUID()
        let second = UUID()
        Self.stub(stub, rows: [
            Self.rowJSON(id: first, author: Self.me, username: "carol", body: "one", at: 30),
            Self.rowJSON(id: second, author: Self.alice, username: "alice", body: "two", at: 31),
        ])
        await model.load()
        let store = EngagementStore()
        let mine = model.comments[0]

        await model.delete(mine, engagement: store)

        #expect(model.comments.map(\.id) == [second])
        #expect(model.message == nil)
        #expect(store.engagement(for: post).commentCount == 1)
    }

    /// The menu mirrors the delete policy: your own comment anywhere, and
    /// anything on your own post. RLS is the enforcement if this is wrong.
    @Test("delete is offered for your own comment anywhere and for anything on your own post")
    func canDelete() {
        let alicesPost = Self.post(by: Self.alice)
        let (onAlicesPost, _) = Self.makeModel(post: alicesPost)
        let mine = Self.comment(by: Self.me, on: alicesPost)
        let bobs = Self.comment(by: Self.bob, on: alicesPost)
        #expect(onAlicesPost.canDelete(mine))
        #expect(onAlicesPost.canDelete(bobs) == false)
        #expect(onAlicesPost.isOwn(mine))
        #expect(onAlicesPost.isOwn(bobs) == false)

        let myPost = Self.post(by: Self.me)
        let (onMyPost, _) = Self.makeModel(post: myPost)
        #expect(onMyPost.canDelete(Self.comment(by: Self.bob, on: myPost)))
        #expect(onMyPost.canDelete(Self.comment(by: Self.me, on: myPost)))
    }
}
