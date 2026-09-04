import SwiftUI

/// One post, full size. A grid with no way to see the photo is a dead end,
/// and this is where per-post actions live: Delete for your own (SOL-38),
/// Report for other people's once SOL-42 lands. Reached from a profile's grid.
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

    private var isOwn: Bool { sessionStore.currentUserID == post.authorID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(post.username)
                        .font(.headline)
                    Spacer()
                    if post.visibility == .mutuals {
                        Label(PostVisibility.mutuals.title, systemImage: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                PostImageView(
                    path: post.imagePath,
                    url: post.imageURL,
                    accessibilityLabel: post.caption ?? "Photo by \(post.username)"
                )

                if let caption = post.caption {
                    Text(caption)
                }

                Text(post.createdAt, format: .dateTime.month().day().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let deleteError {
                    Text(deleteError)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOwn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Post", systemImage: "trash")
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .confirmationDialog(
            "Delete this post?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Post", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The photo is removed for everyone who could see it. This can't be undone.")
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
            try await services!.post.deletePost(id: post.id, imagePath: post.imagePath)
            feedInvalidation.markStale()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
