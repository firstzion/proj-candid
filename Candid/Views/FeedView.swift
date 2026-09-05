import SwiftUI

struct FeedView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var posts: [FeedPost] = []
    @State private var phase: Phase = .loading
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

    /// When the posts on screen were fetched. Their signed image URLs stop
    /// resolving `StorageService.signedURLLifetime` after this — see `isStale`.
    @State private var loadedAt: Date?

    /// Bumped by every successful refresh. A `loadMore` that was in flight
    /// across a refresh checks it on return and drops its page: that page was
    /// paginated from a cursor that is no longer in the list, and appending
    /// it would leave a hole between the fresh head and the old tail.
    @State private var generation = 0

    /// Why the last `loadMore` failed, shown as a retry row under the posts.
    /// Swallowing it left someone parked at the bottom with no spinner, no
    /// message and nothing to tap — the last row's `onAppear` does not fire
    /// again until it scrolls off and back on.
    @State private var loadMoreError: String?

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

    /// Another person's post being reported (SOL-42), and — once it is — the
    /// account it was about, so a block can be offered.
    @State private var reportTarget: ReportSheet.Target?
    @State private var reportedProfile: Profile?
    @State private var isOfferingBlock = false

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

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
                switch phase {
                case .loading:
                    ProgressView()

                case .loaded where posts.isEmpty:
                    ContentUnavailableView("No Posts Yet", systemImage: "photo.on.rectangle.angled")

                case .loaded:
                    List {
                        ForEach(posts) { post in
                            feedRow(for: post)
                                .onAppear {
                                    if post.id == posts.last?.id {
                                        Task { await loadMore() }
                                    }
                                }
                        }

                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else if let loadMoreError {
                            VStack(spacing: 8) {
                                Text(loadMoreError)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                Button("Try Again") { Task { await loadMore() } }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await refresh() }

                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Feed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await refresh() } }
                    }
                }
            }
            .navigationTitle("Feed")
            .navigationDestination(item: $selectedProfile) { profile in
                ProfileScreen(profile: profile)
            }
            .confirmationDialog(
                "Delete this post?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible,
                presenting: postToDelete
            ) { post in
                Button("Delete Post", role: .destructive) {
                    Task { await delete(post) }
                }
            } message: { _ in
                Text("The photo is removed for everyone who could see it. This can't be undone.")
            }
            .alert("Something Went Wrong", isPresented: $isShowingActionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
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
            .task {
                // Runs every time the tab is shown; only fetch when there is
                // nothing on screen or what's there has gone stale.
                guard posts.isEmpty || isStale else { return }
                await refresh()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Returning from the background after a long absence is how
                // the feed usually goes stale — and `.task` does not re-run
                // for that, only for the tab appearing.
                guard newPhase == .active, isStale else { return }
                Task { await refresh() }
            }
            .onChange(of: feedInvalidation.version) {
                // A post just succeeded, or the graph just changed — a
                // follow, unfollow, block or unblock. Refresh regardless of
                // `isStale`: the person expects to see the result now, not up
                // to half an hour from now, and `refresh` replaces the list,
                // so rows that are no longer permitted leave with it.
                Task { await refresh() }
            }
        }
    }

    private var isStale: Bool {
        guard let loadedAt else { return false }
        return Date().timeIntervalSince(loadedAt) > Self.staleAfter
    }

    /// Fetches the newest page and replaces the feed with it — the initial
    /// load, pull-to-refresh, and the automatic refresh of a stale feed are
    /// all the same operation.
    ///
    /// Replacing rather than merging is deliberate, for two reasons. Signed
    /// image URLs expire, and a merge that kept the existing posts kept their
    /// dead URLs too, so after an hour every image was a placeholder and
    /// pulling to refresh could not fix it. And a merge that only prepends
    /// what's new leaves a hole whenever more than a page of posts arrived
    /// since the last load: the posts between the new head and the old list
    /// were never fetched, and `loadMore` only ever paginates from the end.
    /// Starting over from the newest page has neither problem; older pages
    /// are re-fetched as the user scrolls.
    private func refresh() async {
        do {
            let page = try await services!.feed.fetchPosts(limit: Self.pageSize)
            generation += 1
            posts = page.posts
            loadedAt = Date()
            reachedEnd = !page.hasMore
            loadMoreError = nil
            phase = .loaded
        } catch {
            // A failed refresh with posts already on screen just leaves them
            // there — the pull-to-refresh spinner dismisses and the user can
            // try again, rather than the whole feed being replaced by an
            // error screen over content that was working fine a moment ago.
            if posts.isEmpty {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, !reachedEnd else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }

        let startedIn = generation
        let page: FeedPage
        do {
            page = try await services!.feed.fetchPosts(before: posts.last?.cursor, limit: Self.pageSize)
        } catch {
            // `reachedEnd` stays false, so the retry row under the posts — or
            // scrolling the last one off and back on, or pulling to refresh —
            // tries again, rather than the whole feed erroring out over
            // content that is fine.
            guard startedIn == generation else { return }
            loadMoreError = error.localizedDescription
            return
        }

        // The feed was refreshed underneath this request — see `generation`.
        guard startedIn == generation else { return }

        append(page.posts)
        reachedEnd = !page.hasMore
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
            try await services!.follow.block(person.id)
            feedInvalidation.markStale()
        } catch {
            actionError = error.localizedDescription
            isShowingActionError = true
        }
    }

    /// Removes the post from the list at once, then asks the server. On
    /// failure the row comes back where it was, with a message. On success
    /// the feed is marked stale as well, so the next refresh — and, once it
    /// exists, the profile grid — comes from the server rather than from a
    /// local edit. Other viewers lose the post at their next refresh, the
    /// same window every graph change already has.
    private func delete(_ post: FeedPost) async {
        let index = posts.firstIndex { $0.id == post.id }
        posts.removeAll { $0.id == post.id }
        do {
            try await services!.post.deletePost(id: post.id, imagePath: post.imagePath)
            feedInvalidation.markStale()
        } catch {
            posts.insert(post, at: min(index ?? posts.count, posts.count))
            actionError = error.localizedDescription
            isShowingActionError = true
        }
    }

    /// Appends only posts not already on screen. Keyset pagination should
    /// never hand back a row twice, but a duplicate `id` in a `List` is a
    /// runtime warning and a misrendered row, so the check is cheap insurance.
    private func append(_ page: [FeedPost]) {
        let existingIDs = Set(posts.map(\.id))
        posts += page.filter { !existingIDs.contains($0.id) }
    }
}

/// One post in the list. Not to be confused with `FeedService`'s row decoder,
/// which is also a "post row" — this one is the view.
private struct FeedPostRow: View {
    let post: FeedPost

    /// Opens the author's profile — from the username, or from VoiceOver's
    /// actions rotor, since the row reads as one element.
    let onOpenProfile: () -> Void

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
                accessibilityLabel: post.caption ?? "Photo by \(post.username)"
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
}
