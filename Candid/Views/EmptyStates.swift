import SwiftUI

/// The six ways a screen can be empty (SOL-40), with deliberate copy in one
/// place and a path forward where there is one.
///
/// Under invite-only onboarding (SOL-43) a new account arrives with one
/// friend, so "following nobody" is no longer the first screen anyone sees —
/// it is what you get after unfollowing everyone — but it still points
/// somewhere: the People tab, where finding people lives. "Nothing yet" is a
/// different state: the person did the right thing and there is just nothing.
/// Someone else's profile with no visible posts says one neutral thing for
/// two meanings on purpose — the post count is computed under RLS (SOL-37),
/// so an account with three friends-only posts reads exactly like one with
/// none, and the existence of hidden posts never leaks.
enum EmptyState: Hashable {
    case feedFollowingNobody
    case feedNothingYet
    case ownProfileNoPosts
    case profileNoVisiblePosts
    case searchNoResults(query: String)
    case blockedProfile(username: String)

    var title: String {
        switch self {
        case .feedFollowingNobody: "You're not following anyone"
        case .feedNothingYet: "Nothing new yet"
        case .ownProfileNoPosts: "You haven't posted yet"
        case .profileNoVisiblePosts: "No posts"
        case .searchNoResults: "No one found"
        case .blockedProfile(let username): "You've blocked @\(username)"
        }
    }

    var message: String {
        switch self {
        case .feedFollowingNobody: "Invite a friend, or search for someone you know."
        case .feedNothingYet: "The people you follow haven't posted anything yet."
        case .ownProfileNoPosts: "Your photos will show up here."
        case .profileNoVisiblePosts: "Nothing to see here yet."
        case .searchNoResults(let query): "No people match “\(query)”."
        case .blockedProfile: "You won't see each other's posts. Unblock to start over."
        }
    }

    var systemImage: String {
        switch self {
        case .feedFollowingNobody: "person.2"
        case .feedNothingYet: "photo.stack"
        case .ownProfileNoPosts: "camera"
        case .profileNoVisiblePosts: "photo.on.rectangle.angled"
        case .searchNoResults: "magnifyingglass"
        case .blockedProfile: "hand.raised"
        }
    }

    /// The one thing to do about it, where there is one. The blocked state's
    /// action is Unblock, which the profile screen already owns.
    var actionTitle: String? {
        switch self {
        case .feedFollowingNobody: "Find People"
        case .ownProfileNoPosts: "Post a Photo"
        default: nil
        }
    }
}

/// The shared look: `ContentUnavailableView` with the state's copy and, where
/// there is one, its action.
struct EmptyStateView: View {
    let state: EmptyState
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(state.title, systemImage: state.systemImage)
        } description: {
            Text(state.message)
        } actions: {
            if let title = state.actionTitle, let action {
                Button(title, action: action)
            }
        }
    }
}

#Preview {
    EmptyStateView(state: .feedFollowingNobody) {}
}
