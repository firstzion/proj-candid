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

/// The shared look: a blank print card, tilted, standing in for the photo
/// that isn't there yet — `ContentUnavailableView`'s SF Symbol + grey type
/// reads too system-generic for an app that otherwise looks like a photo
/// album (design spec, 1i).
struct EmptyStateView: View {
    let state: EmptyState
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.candidSurface)
                    .frame(width: 96, height: 112)
                    .overlay(
                        Rectangle().strokeBorder(Color.candidInk.opacity(0.16))
                    )
                Image(systemName: state.systemImage)
                    .foregroundStyle(.candidFaint)
            }
            .rotationEffect(.degrees(-3))

            Text(state.title)
                .font(.newsreader(24))
                .foregroundStyle(.candidInk)
                .padding(.top, 30)

            Text(state.message)
                .font(.newsreader(17))
                .foregroundStyle(.candidMuted)
                .padding(.top, 9)

            if let title = state.actionTitle, let action {
                Button(action: action) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.candidGround)
                        .padding(.horizontal, 22)
                        .frame(height: 46)
                        .background(Color.candidAccent)
                        .clipShape(Capsule())
                }
                .padding(.top, 26)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 46)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.candidGround)
    }
}

#Preview {
    EmptyStateView(state: .feedFollowingNobody) {}
}
