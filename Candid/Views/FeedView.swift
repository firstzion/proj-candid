import SwiftUI

/// Presentation state only (SOL-77) — which dialog or alert is up, which
/// profile a tapped username navigates to. `FeedModel` owns loading and every
/// mutation; this view keeps the `scenePhase` and `FeedInvalidation`
/// observations, since those are about *when* to reload, not what a reload
/// does.
struct FeedView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(TabSelection.self) private var tabSelection

    /// Built in `.task` rather than `init`: it needs `services`, and
    /// environment values are not readable there. Nil only until the tab is
    /// first shown.
    @State private var model: FeedModel?

    /// The author whose username was just tapped; non-nil pushes their
    /// profile. One of two ways to reach someone from inside the app, and the
    /// only one that does not need their name: this reaches anyone whose post
    /// you can already see, where the People tab (SOL-39) searches by
    /// username.
    @State private var selectedProfile: Profile?

    /// The post whose long-press menu chose Delete, held while the
    /// confirmation is up; and the failure message if the server refused.
    @State private var postToDelete: FeedPost?
    @State private var isConfirmingDelete = false
    @State private var actionError: String?
    @State private var isShowingActionError = false

    /// Another person's post being reported (SOL-42).
    @State private var reportTarget: ReportSheet.Target?

    /// How old the feed may get before it refreshes itself. Half the signed
    /// URL lifetime, so images are swapped for fresh URLs well before the
    /// current ones expire — rather than every photo on screen turning into a
    /// placeholder at the hour mark.
    private static let staleAfter = TimeInterval(StorageService.signedURLLifetime) / 2

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(for: model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Feed")
            .navigationDestination(item: $selectedProfile) { profile in
                ProfileScreen(profile: profile)
            }
            .deletePostConfirmation($postToDelete, isPresented: $isConfirmingDelete) { post in
                Task { await delete(post) }
            }
            .alert("Something Went Wrong", isPresented: $isShowingActionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
            .reportAndBlockFlow(target: $reportTarget) { person in
                await block(person)
            }
            .task {
                // Runs every time the tab is shown; only fetch when there is
                // nothing on screen or what's there has gone stale.
                let feedModel = model ?? makeModel()
                guard feedModel.paged.posts.isEmpty || feedModel.paged.isStale(after: Self.staleAfter) else { return }
                await feedModel.refresh()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Returning from the background after a long absence is how
                // the feed usually goes stale — and `.task` does not re-run
                // for that, only for the tab appearing.
                guard newPhase == .active,
                      let model,
                      model.paged.isStale(after: Self.staleAfter) else { return }
                Task { await model.refresh() }
            }
            .onChange(of: feedInvalidation.version) {
                // A post just succeeded, or the graph just changed — a
                // follow, unfollow, block or unblock. Refresh regardless of
                // staleness: the person expects to see the result now, not up
                // to half an hour from now, and `refresh` replaces the list,
                // so rows that are no longer permitted leave with it.
                guard let model else { return }
                Task { await model.refresh() }
            }
        }
    }

    @ViewBuilder
    private func content(for model: FeedModel) -> some View {
        switch model.paged.phase {
        case .loading:
            ProgressView()

        case .loaded where model.paged.posts.isEmpty:
            if let feedEmptyState = model.feedEmptyState {
                EmptyStateView(state: feedEmptyState) { tabSelection.selected = .people }
            } else {
                ProgressView()
            }

        case .loaded:
            List {
                ForEach(model.paged.posts) { post in
                    feedRow(for: post)
                        .onAppear {
                            if post.id == model.paged.posts.last?.id {
                                Task { await model.paged.loadMore() }
                            }
                        }
                }

                LoadMoreFooter(paged: model.paged)
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Feed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
            }
        }
    }

    private func makeModel() -> FeedModel {
        let feedModel = FeedModel(services: services)
        model = feedModel
        return feedModel
    }

    /// One row, plus its long-press menu: Delete on your own posts (SOL-38),
    /// Report on other people's (SOL-42). Nothing here decides who may
    /// delete: the `posts` delete policy does, and the menu simply isn't
    /// offered where the request would match no rows.
    @ViewBuilder
    private func feedRow(for post: FeedPost) -> some View {
        let row = FeedPostRow(post: post) {
            selectedProfile = Profile(id: post.authorID, username: post.username)
        }
        if post.authorID == sessionStore.currentUserID {
            row.contextMenu {
                Button(role: .destructive) {
                    postToDelete = post
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Post…", systemImage: "trash")
                }
            }
        } else {
            row.contextMenu {
                Button {
                    reportTarget = .post(post)
                } label: {
                    Label("Report…", systemImage: "flag")
                }
            }
        }
    }

    private func block(_ person: Profile) async {
        guard let model, let error = await model.block(person, feedInvalidation: feedInvalidation) else { return }
        actionError = error
        isShowingActionError = true
    }

    private func delete(_ post: FeedPost) async {
        guard let model, let error = await model.delete(post, feedInvalidation: feedInvalidation) else { return }
        actionError = error
        isShowingActionError = true
    }
}

/// One post in the list. Not to be confused with `FeedService`'s row decoder,
/// which is also a "post row" — this one is the view.
private struct FeedPostRow: View {
    let post: FeedPost

    /// Opens the author's profile — from the username, or from VoiceOver's
    /// actions rotor, since the row reads as one element.
    let onOpenProfile: () -> Void

    @Environment(\.services) private var services

    /// How long a post stays on a relative timestamp before switching to an
    /// absolute date — a post from three months ago reading "12 wk" is not
    /// more useful than "Jun 12", and stops changing every time the row
    /// re-renders.
    private static let relativeCutoff: TimeInterval = 7 * 24 * 60 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                // The author's name opens their profile. Plain style, so only
                // the name is the target — not the whole row, which a List
                // would otherwise hand to a default-styled button.
                Button(action: onOpenProfile) {
                    Text(post.username)
                        .font(.headline)
                }
                .buttonStyle(.plain)

                Spacer()

                // Which audience the photo went to. Only the narrower tier is
                // marked: a viewer sees a friends-only post because they are
                // friends with the author, and the author sees which of their
                // own posts went to whom. Followers posts are the default and
                // say nothing.
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

            timestamp
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        // Reads as one element — "username, photo, caption, 5 minutes ago" —
        // rather than four separate stops for VoiceOver to swipe through.
        .accessibilityElement(children: .combine)
        // Combining swallows the username button, so the same action is
        // offered where VoiceOver users expect it: in the actions rotor.
        .accessibilityAction(named: "View profile", onOpenProfile)
    }

    private var timestamp: Text {
        if Date.now.timeIntervalSince(post.createdAt) > Self.relativeCutoff {
            Text(post.createdAt, format: .dateTime.month().day())
        } else {
            Text(post.createdAt, format: .relative(presentation: .named))
        }
    }
}

#Preview {
    FeedView()
        .environmentObject(SessionStore(client: .preview))
        .environment(\.services, AppServices(client: .preview))
        .environment(FeedInvalidation())
        .environment(TabSelection())
}
