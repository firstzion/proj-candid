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
    @State private var reportedProfile: Profile?
    @State private var isOfferingBlock = false

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
                    accessibilityLabel: post.caption ?? "Photo by \(post.username)",
                    imageCache: services.imageCache
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
                }
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target) { person in
                reportedProfile = person
                isOfferingBlock = true
            }
        }
        .confirmationDialog(
            "Reported. Block them too?",
            isPresented: $isOfferingBlock,
            titleVisibility: .visible,
            presenting: reportedProfile
        ) { person in
            Button("Block @\(person.username)", role: .destructive) { Task { await block(person) } }
            Button("Not Now", role: .cancel) {}
        } message: { _ in
            Text("No review queue exists yet, so blocking is how to stop seeing their posts now. You won't see each other's posts, and any follow between you ends. They won't be told.")
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
