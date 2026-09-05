import SwiftUI

/// A person's profile — yours or anyone else's. One screen, switching on "is
/// this me": the header, the three counts and the grid are the same for
/// everyone; only the action row differs. Your own has Edit Username
/// (SOL-41), Invites (SOL-63), Log Out and Delete Account; anyone else's has
/// Follow/Unfollow, Block/Unblock and Report (SOL-42). Reached
/// from the Profile tab, a username in the feed, a search result on the
/// People tab, or a follower list.
///
/// Nothing here decides what may be seen. The post count and the grid are
/// read under RLS, so they are "the posts you can see" — all of them for the
/// author, the followers tier for a one-way follower, none for a stranger —
/// which is exactly what makes "has no posts" and "has posts you can't see"
/// one and the same screen (SOL-40); the true total is never computed for
/// anyone else. The two follow counts are public by decision and come from
/// `follow_counts()`; the lists behind them are readable only at either end
/// of an edge or by a mutual (SOL-66), so they open only from your own
/// profile or a mutual's. The UI knows mutuality from the relationship it
/// already loads; RLS is the enforcement if that is ever wrong.
///
/// Every control is optimistic: the relationship line and the button change
/// the moment they are tapped, and change back with a message if the request
/// fails. Every success marks the feed stale (`FeedInvalidation`), which also
/// reloads this screen — counts and grid come back from the server rather
/// than from a local edit.
struct ProfileScreen: View {
    let profile: Profile

    /// The username as it is now: `profile.username` at first, then whatever
    /// Edit Username changed it to, so the screen never shows a stale name.
    @State private var displayedUsername: String
    @State private var isEditingUsername = false

    init(profile: Profile) {
        self.profile = profile
        _displayedUsername = State(initialValue: profile.username)
    }

    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation
    @Environment(TabSelection.self) private var tabSelection
    @EnvironmentObject private var sessionStore: SessionStore

    /// Nil until loaded; only for someone else's profile.
    @State private var relationship: Relationship?
    @State private var relationshipError: String?
    @State private var followCounts: FollowCounts?
    @State private var postCount: Int?

    @State private var posts: [FeedPost] = []
    @State private var gridPhase: GridPhase = .loading
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

    /// Bumped by every successful reload, so a `loadMore` that was in flight
    /// across one drops its page — see `FeedView.generation`.
    @State private var generation = 0

    @State private var isChanging = false
    @State private var message: FormMessage?
    @State private var isConfirmingBlock = false

    /// Reporting this person (SOL-42), and the block offered once it is done.
    @State private var reportTarget: ReportSheet.Target?
    @State private var isOfferingBlock = false

    @State private var isSigningOut = false
    @State private var isConfirmingDeleteAccount = false
    @State private var isDeletingAccount = false

    @State private var listKind: FollowListView.Kind?
    @State private var selectedPost: FeedPost?
    @State private var postToDelete: FeedPost?
    @State private var isConfirmingDelete = false

    private enum GridPhase {
        case loading
        case loaded
        case failed(String)
    }

    private static let pageSize = FeedService.defaultLimit

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    private var isSelf: Bool { sessionStore.currentUserID == profile.id }

    /// The lists open only where RLS would let them be read.
    private var canOpenLists: Bool { isSelf || relationship?.isMutual == true }

    private var isBlocking: Bool { relationship?.blocking == true }

    @ViewBuilder
    private var messageLine: some View {
        if let message {
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(message.kind == .failure ? Color.red : Color.secondary)
                .padding(.horizontal)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                if isBlocking {
                    // Reachable only by the blocker — the profiles policy hides
                    // the blocker from the blocked — and there is nothing to
                    // count or show: Unblock, in `actions`, is the way back.
                    actions
                    messageLine
                    EmptyStateView(state: .blockedProfile(username: displayedUsername))
                        .frame(maxWidth: .infinity)
                } else {
                    countsRow
                    actions
                    messageLine
                    grid
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(displayedUsername)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingUsername) {
            EditUsernameSheet(currentUsername: displayedUsername) { newName in
                displayedUsername = newName
                // Posts follow the person, not the string: the feed joins
                // profiles, so a refresh shows the new name on old posts.
                feedInvalidation.markStale()
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target) { _ in
                // No review queue exists yet, so the reporter usually wants
                // the content gone from their own view now.
                if relationship?.blocking != true {
                    isOfferingBlock = true
                }
            }
        }
        .confirmationDialog(
            "Reported. Block @\(displayedUsername) too?",
            isPresented: $isOfferingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await block() } }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("You won't see each other's posts, and any follow between you ends. They won't be told.")
        }
        .navigationDestination(item: $listKind) { kind in
            FollowListView(profile: profile, kind: kind)
        }
        .navigationDestination(item: $selectedPost) { post in
            PostDetailView(post: post)
        }
        .task(id: profile.id) { await load() }
        .onChange(of: feedInvalidation.version) {
            // Something changed what the server would hand back — a post, a
            // follow, a block, a delete, here or elsewhere. Reload all of it.
            Task { await load() }
        }
        .confirmationDialog(
            "Block \(profile.username)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await block() } }
        } message: {
            Text("You won't see each other's posts, and any follow between you ends. They won't be told.")
        }
        .confirmationDialog(
            "Delete this post?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible,
            presenting: postToDelete
        ) { post in
            Button("Delete Post", role: .destructive) { Task { await delete(post) } }
        } message: { _ in
            Text("The photo is removed for everyone who could see it. This can't be undone.")
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isConfirmingDeleteAccount,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) { Task { await deleteAccount() } }
        } message: {
            Text("This permanently deletes your account and every photo you've posted. This can't be undone.")
        }
    }

    // MARK: - Header, counts and actions

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayedUsername)
                .font(.title2)

            if isSelf {
                if case .signedIn(_, let email) = sessionStore.state, let email {
                    Text(email)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let relationship {
                Text(Self.summary(of: relationship))
                    .foregroundStyle(.secondary)
            } else if let relationshipError {
                Text(relationshipError)
                    .foregroundStyle(.red)
                Button("Try Again") { Task { await loadRelationship() } }
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal)
    }

    /// Posts, followers, following. The follow counts are buttons only where
    /// the lists behind them can be read; elsewhere they are numbers, dimmed.
    private var countsRow: some View {
        HStack(spacing: 28) {
            countCell(postCount, "posts", isEnabled: true)
            Button { listKind = .followers } label: {
                countCell(followCounts?.followers, "followers", isEnabled: canOpenLists)
            }
            .disabled(!canOpenLists)
            Button { listKind = .following } label: {
                countCell(followCounts?.following, "following", isEnabled: canOpenLists)
            }
            .disabled(!canOpenLists)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func countCell(_ value: Int?, _ label: String, isEnabled: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value.map { "\($0)" } ?? "–")
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actions: some View {
        if isSelf {
            VStack(alignment: .leading, spacing: 12) {
                Button("Edit Username") { isEditingUsername = true }
                NavigationLink {
                    InvitesView()
                } label: {
                    Label("Invites", systemImage: "envelope")
                }
                Button("Log Out") { Task { await signOut() } }
                    .disabled(isSigningOut)
                Button("Delete Account", role: .destructive) { isConfirmingDeleteAccount = true }
                    .disabled(isDeletingAccount)
                if isDeletingAccount {
                    ProgressView()
                }
            }
            .padding(.horizontal)
        } else if let relationship {
            HStack(spacing: 16) {
                if relationship.blocking {
                    Button("Unblock") { Task { await unblock() } }
                } else {
                    Button(relationship.following ? "Unfollow" : "Follow") {
                        Task { await toggleFollow() }
                    }
                    Button("Block", role: .destructive) { isConfirmingBlock = true }
                }
                Button("Report…") { reportTarget = .profile(profile) }
            }
            .buttonStyle(.bordered)
            .disabled(isChanging)
            .padding(.horizontal)
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        switch gridPhase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()

        case .failed(let error):
            VStack(spacing: 8) {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await reload() } }
            }
            .frame(maxWidth: .infinity)
            .padding()

        case .loaded where posts.isEmpty:
            if isSelf {
                EmptyStateView(state: .ownProfileNoPosts) { tabSelection.selected = .post }
                    .frame(maxWidth: .infinity)
            } else {
                // One message for "has no posts" and "has posts you can't
                // see", on purpose (SOL-40): the count and the grid are read
                // under RLS, so the two are indistinguishable by construction.
                EmptyStateView(state: .profileNoVisiblePosts)
                    .frame(maxWidth: .infinity)
            }

        case .loaded:
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(posts) { post in
                    gridCell(for: post)
                        .onAppear {
                            if post.id == posts.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
            }
            if isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }

    /// A square cell that opens the post. Your own cells carry the same
    /// long-press Delete the feed row has (SOL-38).
    @ViewBuilder
    private func gridCell(for post: FeedPost) -> some View {
        let cell = Button {
            selectedPost = post
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PostImageView(
                        path: post.imagePath,
                        url: post.imageURL,
                        accessibilityLabel: post.caption ?? "Photo by \(post.username)",
                        contentMode: .fill,
                        placeholderMinHeight: 0,
                        imageCache: services.imageCache
                    )
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isSelf {
            cell.contextMenu {
                Button(role: .destructive) {
                    postToDelete = post
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Post…", systemImage: "trash")
                }
            }
        } else {
            cell
        }
    }

    // MARK: - Loading

    /// Everything the screen shows, at once; each piece reports its own
    /// failure. Also what runs again whenever the feed is marked stale.
    private func load() async {
        let relationshipLoad = Task { await loadRelationship() }
        let countsLoad = Task { await loadCounts() }
        await reload()
        await relationshipLoad.value
        await countsLoad.value
    }

    private func loadRelationship() async {
        guard !isSelf else { return }
        relationshipError = nil
        do {
            relationship = try await services.follow.relationship(with: profile.id)
        } catch {
            relationshipError = error.localizedDescription
        }
    }

    private func loadCounts() async {
        do {
            followCounts = try await services.follow.counts(for: profile.id)
            postCount = try await services.profile.postCount(for: profile.id)
        } catch {
            message = .failure(error.localizedDescription)
        }
    }

    /// The newest page of the person's posts, replacing the grid — the same
    /// operation for the first load and every refresh, for the reasons
    /// `FeedView.refresh` gives.
    private func reload() async {
        do {
            let page = try await services.feed.fetchPosts(by: profile.id, limit: Self.pageSize)
            generation += 1
            posts = page.posts
            reachedEnd = !page.hasMore
            gridPhase = .loaded
        } catch {
            if posts.isEmpty {
                gridPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, !reachedEnd else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let startedIn = generation
        do {
            let page = try await services.feed.fetchPosts(
                by: profile.id, before: posts.last?.cursor, limit: Self.pageSize
            )
            guard startedIn == generation else { return }
            let existing = Set(posts.map(\.id))
            posts += page.posts.filter { !existing.contains($0.id) }
            reachedEnd = !page.hasMore
        } catch {
            guard startedIn == generation else { return }
            message = .failure(error.localizedDescription)
        }
    }

    // MARK: - Follow and block

    /// The relationship in the app's words. "Friends" is a mutual follow —
    /// the same derivation as the `mutuals` view, on the two rows that matter.
    static func summary(of relationship: Relationship) -> String {
        if relationship.blocking { return "Blocked" }
        if relationship.isMutual { return "Friends" }
        if relationship.following { return "Following" }
        if relationship.followedBy { return "Follows you" }
        return "Not following"
    }

    private func toggleFollow() async {
        guard let previous = relationship else { return }
        var optimistic = previous
        optimistic.following.toggle()
        let wantsToFollow = optimistic.following

        await change(to: optimistic, rollingBackTo: previous) {
            if wantsToFollow {
                try await services.follow.follow(profile.id)
            } else {
                try await services.follow.unfollow(profile.id)
            }
        }
    }

    /// A block severs the follow in both directions in the database; the
    /// optimistic state says so too, rather than waiting to be told.
    private func block() async {
        guard let previous = relationship else { return }
        await change(
            to: Relationship(following: false, followedBy: false, blocking: true),
            rollingBackTo: previous
        ) {
            try await services.follow.block(profile.id)
        }
    }

    /// Unblocking restores nothing — no edge comes back — so the state after
    /// it is "not following", from scratch.
    private func unblock() async {
        guard let previous = relationship else { return }
        await change(to: .unconnected, rollingBackTo: previous) {
            try await services.follow.unblock(profile.id)
        }
    }

    /// The one shape every action takes: show the intended state, make the
    /// request, and either mark the feed stale — which reloads this screen
    /// too — or put the old state back with a message.
    private func change(
        to optimistic: Relationship,
        rollingBackTo previous: Relationship,
        _ request: () async throws -> Void
    ) async {
        message = nil
        isChanging = true
        defer { isChanging = false }

        relationship = optimistic
        do {
            try await request()
            feedInvalidation.markStale()
        } catch {
            relationship = previous
            message = .failure(error.localizedDescription)
        }
    }

    // MARK: - Your own posts and account

    /// Row first, then object, in `PostService.deletePost`; here the cell
    /// leaves the grid and the count drops, and the feed is marked stale so
    /// everything else refetches.
    private func delete(_ post: FeedPost) async {
        do {
            try await services.post.deletePost(id: post.id, imagePath: post.imagePath)
            posts.removeAll { $0.id == post.id }
            postCount = postCount.map { max(0, $0 - 1) }
            feedInvalidation.markStale()
        } catch {
            message = .failure(error.localizedDescription)
        }
    }

    private func signOut() async {
        isSigningOut = true
        message = nil
        defer { isSigningOut = false }

        do {
            try await sessionStore.signOut()
        } catch {
            // The SDK clears the local session before calling the server, so
            // the app is already signed out; this only reports that the
            // server-side token revocation did not go through.
            message = .failure("Signed out on this device, but the server call failed: \(error.localizedDescription)")
        }
    }

    /// Deletes the account, then signs out through `SessionStore` exactly like
    /// Log Out — the SDK's auth-state stream carries the app back to the Log
    /// In screen either way.
    private func deleteAccount() async {
        isDeletingAccount = true
        message = nil
        defer { isDeletingAccount = false }

        do {
            try await services.profile.deleteAccount()
            try await sessionStore.signOut()
        } catch {
            message = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        ProfileScreen(profile: Profile(id: UUID(), username: "alice"))
    }
    .environmentObject(SessionStore(client: .preview))
    .environment(\.services, AppServices(client: .preview))
    .environment(FeedInvalidation())
    .environment(TabSelection())
}
