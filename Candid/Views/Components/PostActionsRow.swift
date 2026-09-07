import SwiftUI

/// The row under a photo: the heart and its count (SOL-89), and the comment
/// bubble and its count (SOL-90). One component for the feed row and the
/// detail view, so the two cannot drift. Reads nothing itself — the caller
/// passes what `EngagementStore` says to show — and decides nothing: the
/// like policy is the database's.
///
/// Counts hide at zero. A row of zeros is noise on a quiet network, and a
/// first like appearing as a number reads as the event it is. Chrome type is
/// SF, as everywhere else; only what a person wrote is set in Newsreader.
struct PostActionsRow: View {
    let engagement: PostEngagement

    /// A like request is out for this post; the heart waits for it rather
    /// than racing a second one — see `EngagementStore.toggleLike`.
    let isBusy: Bool

    let onToggleLike: () -> Void

    /// Opens the post's thread (SOL-90).
    let onOpenComments: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Button(action: onToggleLike) {
                HStack(spacing: 6) {
                    Image(systemName: engagement.isLikedByViewer ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                        .foregroundStyle(engagement.isLikedByViewer ? Color.candidAccent : Color.candidMuted)
                        .contentTransition(.symbolEffect(.replace))
                    if engagement.likeCount > 0 {
                        Text("\(engagement.likeCount)")
                            .font(.system(size: 13.5))
                            .monospacedDigit()
                            .foregroundStyle(.candidMuted)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(engagement.isLikedByViewer ? "Unlike" : "Like")
            .accessibilityValue("\(engagement.likeCount) likes")
            // A light tap on like only, not on unlike.
            .sensoryFeedback(.impact(weight: .light), trigger: engagement.isLikedByViewer) { _, isLiked in
                isLiked
            }

            Button(action: onOpenComments) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 20))
                        .foregroundStyle(.candidMuted)
                    if engagement.commentCount > 0 {
                        Text("\(engagement.commentCount)")
                            .font(.system(size: 13.5))
                            .monospacedDigit()
                            .foregroundStyle(.candidMuted)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Comments")
            .accessibilityValue("\(engagement.commentCount) comments")

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        PostActionsRow(engagement: PostEngagement(likeCount: 3, commentCount: 2, isLikedByViewer: true), isBusy: false, onToggleLike: {}, onOpenComments: {})
        PostActionsRow(engagement: PostEngagement(likeCount: 0, commentCount: 0, isLikedByViewer: false), isBusy: false, onToggleLike: {}, onOpenComments: {})
    }
    .padding()
    .background(Color.candidGround)
}
