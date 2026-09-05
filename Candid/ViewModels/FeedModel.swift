import Foundation
import Observation

/// Everything `FeedView` loads and mutates (SOL-77), carried over unchanged
/// from the view: which page is on screen (via `PagedPosts`, SOL-71), which
/// of the two empty states an empty feed is, deleting a post and blocking
/// from a report. The view keeps the `scenePhase` and `FeedInvalidation`
/// *observations* — those are how the view decides *when* to reload — and
/// calls into this for everything about *what* a reload does.
@MainActor
@Observable
final class FeedModel {
    /// Which of the two empties an empty feed is (SOL-40), decided after a
    /// refresh that came back with nothing; nil while that is being decided.
    private(set) var feedEmptyState: EmptyState?

    let paged: PagedPosts

    private let services: AppServices

    init(services: AppServices, pageSize: Int = FeedService.defaultLimit) {
        self.services = services
        paged = PagedPosts(source: services.feed, pageSize: pageSize)
    }

    /// The newest page, replacing the feed — see `PagedPosts.refresh()` for
    /// why it replaces rather than merges. The only thing that belongs here
    /// rather than in `PagedPosts` is which empty an empty feed is.
    func refresh() async {
        guard let page = await paged.refresh() else { return }
        feedEmptyState = page.posts.isEmpty ? await decidedEmptyState() : nil
    }

    /// Two different empties, told apart by one number (SOL-40). Following
    /// nobody is what you see after unfollowing everyone — under invite-only
    /// onboarding a new account arrives with a friend — and it points to the
    /// People tab; following people who haven't posted is not a problem to
    /// solve, so it just says so. If the count itself fails, "nothing yet" is
    /// the safer wrong answer: it prompts nothing.
    private func decidedEmptyState() async -> EmptyState {
        let count = (try? await services.follow.followingCount()) ?? 1
        return count == 0 ? .feedFollowingNobody : .feedNothingYet
    }

    /// Removes the post from the list at once, then asks the server. On
    /// failure the row comes back where it was. On success the feed is
    /// marked stale as well, so the next refresh — and the profile grid —
    /// comes from the server rather than from a local edit. Returns an error
    /// message for the view to show on failure, nil on success.
    func delete(_ post: FeedPost, feedInvalidation: FeedInvalidation) async -> String? {
        let index = paged.remove(id: post.id)
        do {
            try await services.post.deletePost(id: post.id, imagePath: post.imagePath)
            feedInvalidation.markStale()
            return nil
        } catch {
            paged.insert(post, at: index)
            return error.localizedDescription
        }
    }

    /// The follow-up a report offers: the same block the profile makes. The
    /// database severs any follow and hides both sides from each other; the
    /// refresh that follows takes their posts out of the list.
    func block(_ person: Profile, feedInvalidation: FeedInvalidation) async -> String? {
        do {
            try await services.follow.block(person.id)
            feedInvalidation.markStale()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
