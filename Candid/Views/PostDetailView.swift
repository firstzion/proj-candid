import SwiftUI

/// One post, full size. A grid with no way to see the photo is a dead end,
/// and this is where per-post actions live: Delete for your own (SOL-38),
/// Report for other people's (SOL-42). Reached from a profile's grid.
///
/// The image comes from `ImageCache` by storage path, so a cell that was on
/// screen a moment ago opens without a download.
struct PostDetailView: View {
    let post: FeedPost

    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    @State private var reportTarget: ReportSheet.Target?

    private var isOwn: Bool { sessionStore.currentUserID == post.authorID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Avatar(username: post.username)
                    Text(post.username)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.candidInk)
                    Spacer()
                    if post.visibility == .mutuals {
                        Label(PostVisibility.mutuals.title, systemImage: "person.2")
                            .font(.caption)
                            .foregroundStyle(.candidMuted)
                    }
                }

                PostImageView(
                    path: post.imagePath,
                    url: post.imageURL,
                    accessibilityLabel: post.caption ?? "Photo by \(post.username)",
                    imageCache: services.imageCache
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let caption = post.caption {
                    Text(caption)
                        .font(.newsreader(17.5))
                        .foregroundStyle(.candidBody)
                }

                Text(post.createdAt, format: .dateTime.month().day().year().hour().minute())
                    .font(.system(size: 13))
                    .foregroundStyle(.candidMuted)

                if let deleteError {
                    Text(deleteError)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .background(Color.candidGround)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Post")
                    .font(.newsreader(19))
                    .foregroundStyle(.candidInk)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isOwn {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Post", systemImage: "trash")
                    }
                    .disabled(isDeleting)
                } else {
                    Button {
                        reportTarget = .post(post)
                    } label: {
                        Label("Report Post", systemImage: "flag")
                    }
                    .foregroundStyle(.candidAccent)
                }
            }
        }
        .reportAndBlockFlow(target: $reportTarget) { person in
            await block(person)
        }
        .deletePostConfirmation(.constant(post), isPresented: $isConfirmingDelete) { _ in
            Task { await delete() }
        }
    }

    /// The follow-up a report offers. Blocking hides both sides from each
    /// other, so this post is gone from the viewer's world: mark the feed
    /// stale — which reloads the profile behind this screen — and go back.
    private func block(_ person: Profile) async {
        deleteError = nil
        do {
            try await services.follow.block(person.id)
            feedInvalidation.markStale()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Row first, then object (`PostService.deletePost`). On success the feed
    /// is marked stale — which reloads the profile behind this screen — and
    /// this screen goes away, since what it showed no longer exists.
    private func delete() async {
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }

        do {
            try await services.post.deletePost(id: post.id, imagePath: post.imagePath)
            feedInvalidation.markStale()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
