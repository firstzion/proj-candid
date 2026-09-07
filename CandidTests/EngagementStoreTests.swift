import Foundation
import Testing
@testable import Candid

/// A one-shot signal, as in `PagedPostsTests`: `wait()` suspends until
/// someone calls `send()`, and returns immediately ever after.
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

/// A `PostLiking` the test drives directly: records every call, fails on
/// demand, and can hold a call open so a second tap can be made while the
/// first is still out — which is the reason the protocol exists.
private final class FakeLiker: PostLiking, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case like(UUID)
        case unlike(UUID)
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "Couldn't like that right now." }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let failure: Failure?
    private let hold: (@Sendable () async -> Void)?

    init(failing: Bool = false, hold: (@Sendable () async -> Void)? = nil) {
        failure = failing ? Failure() : nil
        self.hold = hold
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func like(post postID: UUID) async throws {
        try await perform(.like(postID))
    }

    func unlike(post postID: UUID) async throws {
        try await perform(.unlike(postID))
    }

    private func perform(_ call: Call) async throws {
        lock.withLock { recorded.append(call) }
        if let hold { await hold() }
        if let failure { throw failure }
    }
}

/// `EngagementStore` (SOL-89): the optimistic like with rollback, the guard
/// against a second tap mid-request, and the base-match rule that lets a
/// fresher server row win over a stale override without anyone clearing it.
@MainActor
@Suite("Engagement store")
struct EngagementStoreTests {
    private static func post(_ engagement: PostEngagement, id: UUID = UUID()) -> FeedPost {
        FeedPost(
            id: id,
            authorID: UUID(),
            imagePath: "\(UUID().uuidString.lowercased())/photo.jpg",
            imageURL: nil,
            caption: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            username: "alice",
            visibility: .followers,
            engagement: engagement,
            cursor: FeedCursor(createdAt: "2026-09-04T14:04:30.909561+00:00", id: id)
        )
    }

    @Test("a like flips the state and adds one, at once")
    func likeIsOptimistic() async {
        let store = EngagementStore()
        let liker = FakeLiker()
        let post = Self.post(PostEngagement(likeCount: 2, commentCount: 0, isLikedByViewer: false))

        let error = await store.toggleLike(on: post, using: liker)

        #expect(error == nil)
        #expect(store.engagement(for: post) == PostEngagement(likeCount: 3, commentCount: 0, isLikedByViewer: true))
        #expect(liker.calls == [.like(post.id)])
    }

    @Test("an unlike subtracts one and never goes below zero")
    func unlikeNeverNegative() async {
        let store = EngagementStore()
        let liker = FakeLiker()
        let post = Self.post(PostEngagement(likeCount: 0, commentCount: 0, isLikedByViewer: true))

        _ = await store.toggleLike(on: post, using: liker)

        #expect(store.engagement(for: post) == PostEngagement(likeCount: 0, commentCount: 0, isLikedByViewer: false))
        #expect(liker.calls == [.unlike(post.id)])
    }

    @Test("a failed toggle restores the row's own value and returns the message")
    func failureRestoresRow() async {
        let store = EngagementStore()
        let liker = FakeLiker(failing: true)
        let post = Self.post(PostEngagement(likeCount: 2, commentCount: 0, isLikedByViewer: false))

        let error = await store.toggleLike(on: post, using: liker)

        #expect(error == "Couldn't like that right now.")
        #expect(store.engagement(for: post) == post.engagement)
        // Nothing left to remember: the override is gone, not parked.
        #expect(store.overrides[post.id] == nil)
    }

    /// What was shown before the tap may itself have been an override — a
    /// comment added a moment ago — and that is what comes back, not the row.
    @Test("a failed toggle restores an earlier override, not the row")
    func failureRestoresShownOverride() async {
        let store = EngagementStore()
        let liker = FakeLiker(failing: true)
        let post = Self.post(PostEngagement(likeCount: 2, commentCount: 1, isLikedByViewer: false))
        store.commentAdded(to: post)

        _ = await store.toggleLike(on: post, using: liker)

        #expect(store.engagement(for: post) == PostEngagement(likeCount: 2, commentCount: 2, isLikedByViewer: false))
    }

    /// A like and an unlike completing out of order would leave the screen
    /// and the server disagreeing, so the second tap is dropped.
    @Test("a second tap while a request is in flight is ignored")
    func inFlightGuard() async {
        let started = AsyncSignal()
        let release = AsyncSignal()
        let liker = FakeLiker(hold: {
            await started.send()
            await release.wait()
        })
        let store = EngagementStore()
        let post = Self.post(PostEngagement(likeCount: 0, commentCount: 0, isLikedByViewer: false))

        let first = Task { await store.toggleLike(on: post, using: liker) }
        // The first tap is now inside the service call, holding.
        await started.wait()
        #expect(store.isBusy(post.id))

        let second = await store.toggleLike(on: post, using: liker)

        #expect(second == nil)
        #expect(liker.calls.count == 1)
        #expect(store.engagement(for: post) == PostEngagement(likeCount: 1, commentCount: 0, isLikedByViewer: true))

        await release.send()
        _ = await first.value
        #expect(store.isBusy(post.id) == false)
        #expect(store.engagement(for: post) == PostEngagement(likeCount: 1, commentCount: 0, isLikedByViewer: true))
    }

    /// The base-match rule. A refetched row that says something different
    /// wins over the override; a copy of the old row still on another screen
    /// keeps showing the optimistic value until it, too, is refetched.
    @Test("an override applies only while the row still matches the one it came from")
    func overrideFollowsTheRow() async {
        let store = EngagementStore()
        let liker = FakeLiker()
        let post = Self.post(PostEngagement(likeCount: 2, commentCount: 0, isLikedByViewer: false))

        _ = await store.toggleLike(on: post, using: liker)

        let fresh = Self.post(PostEngagement(likeCount: 4, commentCount: 0, isLikedByViewer: true), id: post.id)
        #expect(store.engagement(for: fresh) == fresh.engagement)
        #expect(store.engagement(for: post) == PostEngagement(likeCount: 3, commentCount: 0, isLikedByViewer: true))
    }

    @Test("comment counts move with the thread and never go below zero")
    func commentCounts() {
        let store = EngagementStore()
        let post = Self.post(PostEngagement(likeCount: 0, commentCount: 1, isLikedByViewer: false))

        store.commentAdded(to: post)
        #expect(store.engagement(for: post).commentCount == 2)

        store.commentRemoved(from: post)
        store.commentRemoved(from: post)
        store.commentRemoved(from: post)
        #expect(store.engagement(for: post).commentCount == 0)
    }
}
