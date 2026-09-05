import SwiftUI

struct FeedView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(TabSelection.self) private var tabSelection

    /// The posts, and everything about paging through them (SOL-71) — shared
    /// with the profile grid so the two cannot drift again.
    ///
    /// Built in `.task` rather than `init`: it needs `services`, and
    /// environment values are not readable there. Nil only until the tab is
    /// first shown.
    @State private var paged: PagedPosts?

    /// Which of the two empties an empty feed is (SOL-40), decided after a
    /// refresh that came back with nothing; nil while that is being decided.
    @State private var feedEmptyState: EmptyState?

    /// The author whose username was just tapped; non-nil pushes their
    /// profile. Before search exists this is the one way to reach someone
    /// from inside the app — though only someone whose post you can already
    /// see, which is why the Profile tab also has a lookup by name.
    @State private var selectedProfile: Profile?

    /// The post whose long-press menu chose Delete, held while the
    /// confirmation is up; and the failure message if the server refused.
    @State private var postToDelete: FeedPost?
    @State private var isConfirmingDelete = false
    @State private var actionError: String?
    @State private var isShowingActionError = false

    /// Another person's post being reported (SOL-42).
    @State private var reportTarget: ReportSheet.Target?

    /// Posts per page. Each page costs two round trips — the rows, then their
    /// signed URLs — so this is the service's default rather than the value of
    /// 8 that had been left in from verifying pagination by hand.
    private static let pageSize = FeedService.defaultLimit

    /// How old the feed may get before it refreshes itself. Half the signed
    /// URL lifetime, so images are swapped for fresh URLs well before the
    /// current ones expire — rather than every photo on screen turning into a
    /// placeholder at the hour mark.
    private static let staleAfter = TimeInterval(StorageService.signedURLLifetime) / 2

    var body: some View {
        NavigationStack {
            Group {
                if let paged {
                    content(for: paged)
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
                let model = paged ?? makePaged()
                guard model.posts.isEmpty || model.isStale(after: Self.staleAfter) else { return }
                await refresh(model)
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Returning from the background after a long absence is how
                // the feed usually goes stale — and `.task` does not re-run
                // for that, only for the tab appearing.
                guard newPhase == .active,
                      let paged,
                      paged.isStale(after: Self.staleAfter) else { return }
                Task { await refresh(paged) }
            }
            .onChange(of: feedInvalidation.version) {
                // A post just succeeded, or the graph just changed — a
                // follow, unfollow, block or unblock. Refresh regardless of
                // staleness: the person expects to see the result now, not up
                // to half an hour from now, and `refresh` replaces the list,
                // so rows that are no longer permitted leave with it.
                guard let paged else { return }
                Task { await refresh(paged) }
            }
        }
    }

    @ViewBuilder
    private func content(for paged: PagedPosts) -> some View {
        switch paged.phase {
        case .loading:
            ProgressView()

        case .loaded where paged.posts.isEmpty:
            if let feedEmptyState {
                EmptyStateView(state: feedEmptyState) { tabSelection.selected = .people }
            } else {
                ProgressView()
            }

        case .loaded:
            List {
                ForEach(paged.posts) { post in
                    feedRow(for: post)
                        .onAppear {
                            if post.id == paged.posts.last?.id {
                                Task { await paged.loadMore() }
                            }
                        }
                }

                LoadMoreFooter(paged: paged)
            }
            .listStyle(.plain)
            .refreshable { await refresh(paged) }

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Feed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await refresh(paged) } }
            }
        }
    }

    private func makePaged() -> PagedPosts {
        let model = PagedPosts(source: services.feed, pageSize: Self.pageSize)
        paged = model
        return model
    }

    /// The newest page, replacing the feed — see `PagedPosts.refresh()` for
    /// why it replaces rather than merges. The only thing that belongs here
    /// rather than in the model is which empty an empty feed is.
    private func refresh(_ paged: PagedPosts) async {
        guard let page = await paged.refresh() else { return }
        if page.posts.isEmpty {
            feedEmptyState = await decidedEmptyState()
        } else {
            feedEmptyState = nil
        }
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

    /// The follow-up a report offers: the same block the profile makes. The
    /// database severs any follow and hides both sides from each other; the
    /// refresh that follows takes their posts out of the list.
    private func block(_ person: Profile) async {
        do {
            try await services.follow.block(person.id)
            feedInvalidation.markStale()
        } catch {
            actionError = error.localizedDescription
            isShowingActionError = true
        }
    }

    /// Removes the post from the list at once, then asks the server. On
    /// failure the row comes back where it was, with a message. On success
    /// the feed is marked stale as well, so the next refresh — and the
    /// profile grid — comes from the server rather than from a local edit.
    /// Other viewers lose the post at their next refresh, the same window
    /// every graph change already has.
    private func delete(_ post: FeedPost) async {
        guard let paged else { return }
        let index = paged.remove(id: post.id)
        do {
            try await services.post.deletePost(id: post.id, imagePath: post.imagePath)
            feedInvalidation.markStale()
        } catch {
            paged.insert(post, at: index)
            actionError = error.localizedDescription
            isShowingActionError = true
        }
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
