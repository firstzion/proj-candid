import Foundation
import Testing
@testable import Candid

/// A one-shot signal: `wait()` suspends until someone calls `send()`, and
/// returns immediately ever after. Enough to pin down the order of two
/// overlapping requests without sleeping.
private actor AsyncSignal {
    private var isSent = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func send() {
        isSent = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func wait() async {
        if isSent { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// A `PostsPaging` the test drives directly, which is the reason the protocol
/// exists: the guard against a stale page needs one `fetchPosts` held open
/// while another completes, and staging that through canned HTTP responses
/// means blocking inside a `URLProtocol` callback.
///
/// Results are answered from a queue in call order. Every call is recorded, so
/// the author scope, page size and cursor a model asked for can be asserted.
private final class FakePostsSource: PostsPaging, @unchecked Sendable {
    struct Call: Sendable {
        let authorID: UUID?
        let cursor: FeedCursor?
        let limit: Int
    }

    enum Failure: Error {
        /// More calls than the test queued — a test bug, surfaced rather than
        /// left to look like a legitimate empty page.
        case queueExhausted
    }

    private let lock = NSLock()
    private var queued: [Result<FeedPage, Error>]
    private var recorded: [Call] = []
    private var holds: [Int: @Sendable () async -> Void] = [:]

    init(_ results: [Result<FeedPage, Error>]) {
        queued = results
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Runs `work` before the call at `index` returns — the hook a test uses
    /// to let a later request finish first.
    func hold(call index: Int, until work: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        holds[index] = work
    }

    func fetchPosts(by authorID: UUID?, before cursor: FeedCursor?, limit: Int) async throws -> FeedPage {
        // Scoped locking rather than a lock()/unlock() pair: plain NSLock
        // calls are unavailable directly inside an async function, and this
        // also guarantees the unlock happens before the `await` below rather
        // than straddling it.
        let (result, hold): (Result<FeedPage, Error>, (@Sendable () async -> Void)?) = lock.withLock {
            let index = recorded.count
            recorded.append(Call(authorID: authorID, cursor: cursor, limit: limit))
            let result: Result<FeedPage, Error> = queued.isEmpty
                ? .failure(Failure.queueExhausted)
                : queued.removeFirst()
            return (result, holds[index])
        }

        if let hold { await hold() }
        return try result.get()
    }
}

@MainActor
@Suite("Paged posts")
struct PagedPostsTests {
    private static func post(_ label: String, at seconds: Int) -> FeedPost {
        let author = UUID()
        return FeedPost(
            id: UUID(),
            authorID: author,
            imagePath: "\(author.uuidString.lowercased())/\(label).jpg",
            imageURL: nil,
            caption: label,
            createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
            username: "alice",
            visibility: .followers,
            cursor: FeedCursor(createdAt: "2026-09-04T14:04:\(seconds).909561+00:00", id: UUID())
        )
    }

    private static func page(_ posts: [FeedPost], hasMore: Bool) -> FeedPage {
        FeedPage(posts: posts, hasMore: hasMore)
    }

    // MARK: - Refresh

    @Test("refresh replaces the list and takes reachedEnd from hasMore")
    func refreshReplaces() async {
        let first = Self.post("a", at: 10)
        let second = Self.post("b", at: 20)
        let source = FakePostsSource([
            .success(Self.page([first], hasMore: true)),
            .success(Self.page([second], hasMore: false)),
        ])
        let model = PagedPosts(source: source)

        await model.refresh()
        #expect(model.posts.map(\.id) == [first.id])
        #expect(model.reachedEnd == false)
        #expect(model.phase == .loaded)

        await model.refresh()
        // Replaced, not merged — see PagedPosts.refresh for why.
        #expect(model.posts.map(\.id) == [second.id])
        #expect(model.reachedEnd)
    }

    @Test("refresh passes the author scope and page size through, with no cursor")
    func refreshRequestShape() async {
        let author = UUID()
        let source = FakePostsSource([.success(Self.page([], hasMore: false))])
        let model = PagedPosts(source: source, authorID: author, pageSize: 7)

        await model.refresh()

        #expect(source.calls.count == 1)
        #expect(source.calls.first?.authorID == author)
        #expect(source.calls.first?.limit == 7)
        #expect(source.calls.first?.cursor == nil)
    }

    @Test("a failed refresh with posts on screen leaves them there")
    func refreshFailureKeepsPosts() async {
        let existing = Self.post("a", at: 10)
        let source = FakePostsSource([
            .success(Self.page([existing], hasMore: false)),
            .failure(FeedServiceError.other("boom")),
        ])
        let model = PagedPosts(source: source)

        await model.refresh()
        let page = await model.refresh()

        #expect(page == nil)
        #expect(model.posts.map(\.id) == [existing.id])
        #expect(model.phase == .loaded)
    }

    @Test("a failed refresh with nothing on screen is the failed phase")
    func refreshFailureWithEmptyList() async {
        let source = FakePostsSource([.failure(FeedServiceError.other("boom"))])
        let model = PagedPosts(source: source)

        await model.refresh()

        #expect(model.posts.isEmpty)
        #expect(model.phase == .failed("boom"))
    }

    // MARK: - Load more

    @Test("loadMore appends from the last post's cursor and skips ids already shown")
    func loadMoreAppendsAndDedupes() async {
        let first = Self.post("a", at: 10)
        let second = Self.post("b", at: 20)
        let third = Self.post("c", at: 30)
        let source = FakePostsSource([
            .success(Self.page([first, second], hasMore: true)),
            // `second` comes back a second time; a duplicate id in a List is a
            // runtime warning and a misrendered row.
            .success(Self.page([second, third], hasMore: false)),
        ])
        let model = PagedPosts(source: source)

        await model.refresh()
        await model.loadMore()

        #expect(model.posts.map(\.id) == [first.id, second.id, third.id])
        #expect(model.reachedEnd)
        #expect(source.calls.count == 2)
        #expect(source.calls.last?.cursor == second.cursor)
    }

    @Test("loadMore does nothing once the end has been reached")
    func loadMoreStopsAtTheEnd() async {
        let source = FakePostsSource([.success(Self.page([Self.post("a", at: 10)], hasMore: false))])
        let model = PagedPosts(source: source)

        await model.refresh()
        await model.loadMore()

        #expect(source.calls.count == 1)
    }

    @Test("a failed loadMore is reported and retried, leaving the list alone")
    func loadMoreFailure() async {
        let first = Self.post("a", at: 10)
        let second = Self.post("b", at: 20)
        let source = FakePostsSource([
            .success(Self.page([first], hasMore: true)),
            .failure(FeedServiceError.other("no more for you")),
            .success(Self.page([second], hasMore: false)),
        ])
        let model = PagedPosts(source: source)

        await model.refresh()
        await model.loadMore()

        #expect(model.loadMoreError == "no more for you")
        #expect(model.posts.map(\.id) == [first.id])
        // Still false, so the retry row — or scrolling the last row off and
        // back on — can try again.
        #expect(model.reachedEnd == false)
        #expect(model.phase == .loaded)

        await model.loadMore()

        #expect(model.loadMoreError == nil)
        #expect(model.posts.map(\.id) == [first.id, second.id])
    }

    /// The generation guard. A page paginated from a cursor that is no longer
    /// in the list would leave a hole between the fresh head and the old tail,
    /// so it is dropped rather than appended.
    @Test("a loadMore that a refresh overtook drops its page")
    func stalePageIsDropped() async {
        let original = Self.post("a", at: 10)
        let stale = Self.post("stale", at: 5)
        let refreshed = Self.post("fresh", at: 30)

        let source = FakePostsSource([
            .success(Self.page([original], hasMore: true)),   // call 0: first refresh
            .success(Self.page([stale], hasMore: true)),      // call 1: the load-more, held
            .success(Self.page([refreshed], hasMore: false)), // call 2: the refresh that overtakes it
        ])
        let model = PagedPosts(source: source)
        await model.refresh()

        let started = AsyncSignal()
        let release = AsyncSignal()
        source.hold(call: 1) {
            await started.send()
            await release.wait()
        }

        let loadMore = Task { await model.loadMore() }
        // The load-more is now inside fetchPosts, holding its page.
        await started.wait()

        await model.refresh()
        await release.send()
        await loadMore.value

        #expect(model.posts.map(\.id) == [refreshed.id])
        #expect(model.reachedEnd)
        #expect(model.isLoadingMore == false)
    }

    // MARK: - Optimistic removal

    @Test("remove reports where a post was so a failed delete can put it back")
    func removeAndInsert() async {
        let first = Self.post("a", at: 10)
        let second = Self.post("b", at: 20)
        let third = Self.post("c", at: 30)
        let source = FakePostsSource([.success(Self.page([first, second, third], hasMore: false))])
        let model = PagedPosts(source: source)
        await model.refresh()

        let index = model.remove(id: second.id)

        #expect(index == 1)
        #expect(model.posts.map(\.id) == [first.id, third.id])

        model.insert(second, at: index)
        #expect(model.posts.map(\.id) == [first.id, second.id, third.id])
    }

    @Test("removing a post that is not on screen changes nothing")
    func removeMissing() async {
        let source = FakePostsSource([.success(Self.page([Self.post("a", at: 10)], hasMore: false))])
        let model = PagedPosts(source: source)
        await model.refresh()

        #expect(model.remove(id: UUID()) == nil)
        #expect(model.posts.count == 1)
    }

    /// The list can have been refreshed between the removal and the failure,
    /// so the old index may be past the end by then.
    @Test("insert past the end appends instead of trapping")
    func insertPastTheEnd() async {
        let source = FakePostsSource([.success(Self.page([], hasMore: false))])
        let model = PagedPosts(source: source)
        await model.refresh()

        let post = Self.post("a", at: 10)
        model.insert(post, at: 99)
        #expect(model.posts.map(\.id) == [post.id])
    }

    // MARK: - Staleness

    @Test("nothing is stale before the first load")
    func staleBeforeLoading() {
        let model = PagedPosts(source: FakePostsSource([]))
        #expect(model.isStale(after: 0) == false)
    }

    @Test("staleness is measured from the last successful refresh")
    func staleAfterInterval() async throws {
        let source = FakePostsSource([.success(Self.page([], hasMore: false))])
        let model = PagedPosts(source: source)
        await model.refresh()

        let loadedAt = try #require(model.loadedAt)

        #expect(model.isStale(after: 60, now: loadedAt.addingTimeInterval(59)) == false)
        #expect(model.isStale(after: 60, now: loadedAt.addingTimeInterval(61)))
    }
}
