import Foundation
import Observation

/// Everything a profile screen loads and mutates — yours or anyone else's.
///
/// Carried over unchanged from `ProfileScreen` (SOL-77): the relationship,
/// counts and grid loading, optimistic follow/unfollow/block/unblock with
/// rollback, post deletion, sign-out and account deletion. The view keeps
/// only presentation state — which dialog is up, which post is selected —
/// and reads this for everything else, which is what makes the logic below
/// reachable from a test instead of only from a running screen.
///
/// `FeedInvalidation` and `SessionStore` are environment-sourced, so — like
/// `SessionStore` itself below — the methods that need them take them as a
/// parameter rather than storing them; the model stays constructible without
/// standing up the environment.
@MainActor
@Observable
final class ProfileModel {
    let profile: Profile
    private(set) var displayedUsername: String
    private(set) var relationship: Relationship?
    private(set) var relationshipError: String?
    private(set) var followCounts: FollowCounts?
    private(set) var postCount: Int?
    private(set) var message: FormMessage?
    private(set) var isChanging = false
    private(set) var isSigningOut = false
    private(set) var isDeletingAccount = false

    /// This person's posts (SOL-71) — the same paging model the feed uses,
    /// scoped to `profile.id`.
    let paged: PagedPosts

    private let services: AppServices
    private let currentUserID: UUID?

    init(profile: Profile, services: AppServices, currentUserID: UUID?, pageSize: Int = FeedService.defaultLimit) {
        self.profile = profile
        self.services = services
        self.currentUserID = currentUserID
        displayedUsername = profile.username
        paged = PagedPosts(source: services.feed, authorID: profile.id, pageSize: pageSize)
    }

    var isSelf: Bool { currentUserID == profile.id }

    /// The lists open only where RLS would let them be read.
    var canOpenLists: Bool { isSelf || relationship?.isMutual == true }

    var isBlocking: Bool { relationship?.blocking == true }

    /// Everything the screen shows, at once; each piece reports its own
    /// failure. Also what runs again whenever the feed is marked stale.
    ///
    /// `async let` rather than three unstructured `Task`s: the previous shape
    /// spawned tasks that outlived the view's own `.task` when it was
    /// cancelled, writing into a model whose screen might already be gone.
    /// Structured concurrency ties all three to this call's own lifetime.
    func load() async {
        async let relationshipLoad: Void = loadRelationship()
        async let countsLoad: Void = loadCounts()
        async let postsLoad: FeedPage? = paged.refresh()
        _ = await (relationshipLoad, countsLoad, postsLoad)
    }

    func usernameChanged(to name: String, feedInvalidation: FeedInvalidation) {
        displayedUsername = name
        // Posts follow the person, not the string: the feed joins profiles,
        // so a refresh shows the new name on old posts.
        feedInvalidation.markStale()
    }

    private func loadRelationship() async {
        guard !isSelf else { return }
        relationshipError = nil
        do {
            relationship = try await services.follow.relationship(with: profile.id)
        } catch {
            relationshipError = error.localizedDescription
        }
    }

    private func loadCounts() async {
        do {
            followCounts = try await services.follow.counts(for: profile.id)
            postCount = try await services.profile.postCount(for: profile.id)
        } catch {
            message = .failure(error.localizedDescription)
        }
    }

    // MARK: - Follow and block

    /// The relationship in the app's words. "Friends" is a mutual follow —
    /// the same derivation as the `mutuals` view, on the two rows that matter.
    static func summary(of relationship: Relationship) -> String {
        if relationship.blocking { return "Blocked" }
        if relationship.isMutual { return "Friends" }
        if relationship.following { return "Following" }
        if relationship.followedBy { return "Follows you" }
        return "Not following"
    }

    func toggleFollow(feedInvalidation: FeedInvalidation) async {
        guard let previous = relationship else { return }
        var optimistic = previous
        optimistic.following.toggle()
        let wantsToFollow = optimistic.following

        await change(to: optimistic, rollingBackTo: previous, feedInvalidation: feedInvalidation) {
            if wantsToFollow {
                try await self.services.follow.follow(self.profile.id)
            } else {
                try await self.services.follow.unfollow(self.profile.id)
            }
        }
    }

    /// A block severs the follow in both directions in the database; the
    /// optimistic state says so too, rather than waiting to be told.
    func block(feedInvalidation: FeedInvalidation) async {
        guard let previous = relationship else { return }
        await change(
            to: Relationship(following: false, followedBy: false, blocking: true),
            rollingBackTo: previous,
            feedInvalidation: feedInvalidation
        ) {
            try await self.services.follow.block(self.profile.id)
        }
    }

    /// Unblocking restores nothing — no edge comes back — so the state after
    /// it is "not following", from scratch.
    func unblock(feedInvalidation: FeedInvalidation) async {
        guard let previous = relationship else { return }
        await change(to: .unconnected, rollingBackTo: previous, feedInvalidation: feedInvalidation) {
            try await self.services.follow.unblock(self.profile.id)
        }
    }

    /// The one shape every action takes: show the intended state, make the
    /// request, and either mark the feed stale — which reloads this screen
    /// too — or put the old state back with a message.
    private func change(
        to optimistic: Relationship,
        rollingBackTo previous: Relationship,
        feedInvalidation: FeedInvalidation,
        _ request: @escaping () async throws -> Void
    ) async {
        message = nil
        isChanging = true
        defer { isChanging = false }

        relationship = optimistic
        do {
            try await request()
            feedInvalidation.markStale()
        } catch {
            relationship = previous
            message = .failure(error.localizedDescription)
        }
    }

    // MARK: - Your own posts and account

    /// Row first, then object, in `PostService.deletePost`; here the post
    /// leaves the grid and the count drops, and the feed is marked stale so
    /// everything else refetches.
    func delete(_ post: FeedPost, feedInvalidation: FeedInvalidation) async {
        do {
            try await services.post.deletePost(id: post.id, imagePath: post.imagePath)
            paged.remove(id: post.id)
            postCount = postCount.map { max(0, $0 - 1) }
            feedInvalidation.markStale()
        } catch {
            message = .failure(error.localizedDescription)
        }
    }

    func signOut(_ sessionStore: SessionStore) async {
        isSigningOut = true
        message = nil
        defer { isSigningOut = false }

        do {
            try await sessionStore.signOut()
        } catch {
            // The SDK clears the local session before calling the server, so
            // the app is already signed out; this only reports that the
            // server-side token revocation did not go through.
            message = .failure("Signed out on this device, but the server call failed: \(error.localizedDescription)")
        }
    }

    /// Deletes the account, then signs out through `SessionStore` exactly like
    /// Log Out — the SDK's auth-state stream carries the app back to the Log
    /// In screen either way.
    func deleteAccount(_ sessionStore: SessionStore) async {
        isDeletingAccount = true
        message = nil
        defer { isDeletingAccount = false }

        do {
            try await services.profile.deleteAccount()
            try await sessionStore.signOut()
        } catch {
            message = .failure(error.localizedDescription)
        }
    }
}
