import SwiftUI

/// What sits under a paged list while the next page is coming, or after it
/// failed to.
///
/// Shared by the feed and the profile grid because the two had already
/// drifted: the feed offered a retry, and the grid reported the same failure
/// in its general message line with nothing to tap. One footer means a third
/// list of posts cannot invent a third behaviour.
struct LoadMoreFooter: View {
    let paged: PagedPosts

    var body: some View {
        if paged.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else if let message = paged.loadMoreError {
            VStack(spacing: 8) {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await paged.loadMore() } }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}
