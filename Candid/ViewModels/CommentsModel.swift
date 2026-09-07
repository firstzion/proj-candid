import Foundation
import Observation

/// Everything the thread screen loads and mutates (the SOL-77 shape, for
/// SOL-90): the list, adding to it, removing from it, and — since SOL-91 —
/// liking a comment in place. `CommentsView` keeps only presentation state,
/// which is what makes the logic below reachable from a test.
///
/// `EngagementStore` is environment-sourced, so the methods that move the
/// card's comment count take it as a parameter rather than storing it, the
/// way `ProfileModel` takes `FeedInvalidation`; the model stays constructible
/// without standing up the environment.
@MainActor
@Observable
final class CommentsModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let post: FeedPost
    private(set) var comments: [Comment] = []
    private(set) var phase: Phase = .loading
    private(set) var isSubmitting = false

    /// The last write's failure, shown above the composer; cleared by the
    /// next attempt.
    private(set) var message: FormMessage?

    /// Comments with a like request out, so a second tap waits rather than
    /// races — the guard `EngagementStore` keeps for posts (SOL-91).
    private var likesInFlight: Set<UUID> = []

    private let services: AppServices
    private let currentUserID: UUID?

    init(post: FeedPost, services: AppServices, currentUserID: UUID?) {
        self.post = post
        self.services = services
        self.currentUserID = currentUserID
    }

    /// The whole thread, oldest first, replacing what is on screen — the
    /// initial load and every reload are the same operation. A failed reload
    /// with comments already on screen leaves them there and says so in the
    /// message line rather than replacing the thread with an error.
    func load() async {
        do {
            comments = try await services.comment.comments(for: post.id)
            phase = .loaded
        } catch {
            if comments.isEmpty {
                phase = .failed(error.localizedDescription)
            } else {
                message = .failure(error.localizedDescription)
            }
        }
    }

    func isOwn(_ comment: Comment) -> Bool {
        comment.authorID == currentUserID
    }

    /// Your own comment anywhere, and anything on your own post. Mirrors the
    /// delete policy, which is the enforcement if this is ever wrong: a
    /// delete the policy does not match affects nothing.
    func canDelete(_ comment: Comment) -> Bool {
        isOwn(comment) || post.authorID == currentUserID
    }

    /// Validates, posts, appends the server's own row, and moves the card's
    /// count up through the store. Returns the new comment so the view can
    /// scroll to it; nil, with `message` set, on failure — including the
    /// client-side refusals for a blank or over-long body, which never reach
    /// the server. A second send while one is out is ignored.
    @discardableResult
    func add(_ draft: String, engagement: EngagementStore) async -> Comment? {
        guard !isSubmitting else { return nil }
        message = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let comment = try await services.comment.add(draft, to: post.id)
            comments.append(comment)
            engagement.commentAdded(to: post)
            return comment
        } catch {
            message = .failure(error.localizedDescription)
            return nil
        }
    }

    /// Removes the comment at once, then asks the server; on failure it comes
    /// back where it was — the `FeedModel.delete` shape. On success the
    /// card's count moves down through the store.
    func delete(_ comment: Comment, engagement: EngagementStore) async {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        message = nil
        comments.remove(at: index)

        do {
            try await services.comment.delete(comment.id)
            engagement.commentRemoved(from: post)
        } catch {
            comments.insert(comment, at: min(index, comments.count))
            message = .failure(error.localizedDescription)
        }
    }

    func isLikeBusy(_ comment: Comment) -> Bool {
        likesInFlight.contains(comment.id)
    }

    /// The heart on a comment (SOL-91): flipped in place at once, put back
    /// with a message if the server refuses. Comment likes show on this one
    /// screen, so they need no overlay; the thread reloads on open, and a
    /// restart shows the server's state.
    func toggleLike(on comment: Comment) async {
        guard !likesInFlight.contains(comment.id),
              let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        likesInFlight.insert(comment.id)
        defer { likesInFlight.remove(comment.id) }

        let previous = comments[index]
        var optimistic = previous
        optimistic.isLikedByViewer.toggle()
        optimistic.likeCount = max(0, previous.likeCount + (optimistic.isLikedByViewer ? 1 : -1))
        comments[index] = optimistic
        message = nil

        do {
            if optimistic.isLikedByViewer {
                try await services.like.like(comment: comment.id)
            } else {
                try await services.like.unlike(comment: comment.id)
            }
        } catch {
            if let current = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[current] = previous
            }
            message = .failure(error.localizedDescription)
        }
    }
}
