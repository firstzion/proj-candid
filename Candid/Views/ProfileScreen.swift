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
///
/// This view holds presentation state only (SOL-77) — which dialog or sheet
/// is up, which post is selected. `ProfileModel` owns loading and every
/// mutation, which is what makes that logic reachable from a test.
struct ProfileScreen: View {
    let profile: Profile

    init(profile: Profile) {
        self.profile = profile
    }

    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation
    @Environment(TabSelection.self) private var tabSelection
    @EnvironmentObject private var sessionStore: SessionStore

    /// Built in `.task` rather than `init`, since it needs `services` and
    /// `sessionStore`, neither available there.
    @State private var model: ProfileModel?

    @State private var isEditingUsername = false
    @State private var isConfirmingBlock = false

    /// Reporting this person (SOL-42); the block offered once it is done is
    /// handled by `reportAndBlockFlow`.
    @State private var reportTarget: ReportSheet.Target?

    @State private var isConfirmingDeleteAccount = false

    @State private var listKind: FollowListView.Kind?
    @State private var selectedPost: FeedPost?
    @State private var postToDelete: FeedPost?
    @State private var isConfirmingDelete = false

    /// Pixels on the shorter edge of a grid thumbnail (SOL-80). Three columns
    /// across the widest current iPhone is a cell of about 145 pt, so 436 px
    /// at 3×; 450 covers every size without measuring the cell at runtime,
    /// which would mean laying the grid out once before knowing what to
    /// fetch. Uploads are 1600 px on the long edge
    /// (`StorageService.maxDimension`), so this is roughly a sixteenth of the
    /// bitmap a cell used to decode. An iPad's larger cells will upscale it
    /// slightly; measuring the cell is the fix if that ever matters.
    private static let thumbnailSide: CGFloat = 450

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    @ViewBuilder
    private var messageLine: some View {
        if let message = model?.message {
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
                if model?.isBlocking == true {
                    // Reachable only by the blocker — the profiles policy hides
                    // the blocker from the blocked — and there is nothing to
                    // count or show: Unblock, in `actions`, is the way back.
                    actions
                    messageLine
                    EmptyStateView(state: .blockedProfile(username: model?.displayedUsername ?? profile.username))
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
        .navigationTitle(model?.displayedUsername ?? profile.username)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingUsername) {
            EditUsernameSheet(currentUsername: model?.displayedUsername ?? profile.username) { newName in
                model?.usernameChanged(to: newName, feedInvalidation: feedInvalidation)
            }
        }
        .reportAndBlockFlow(target: $reportTarget, offerBlock: model?.isBlocking != true) { _ in
            await model?.block(feedInvalidation: feedInvalidation)
        }
        .navigationDestination(item: $listKind) { kind in
            FollowListView(profile: profile, kind: kind)
        }
        .navigationDestination(item: $selectedPost) { post in
            PostDetailView(post: post)
        }
        .task(id: profile.id) { await model(for: profile.id).load() }
        .onChange(of: feedInvalidation.version) {
            // Something changed what the server would hand back — a post, a
            // follow, a block, a delete, here or elsewhere. Reload all of it.
            Task { await model(for: profile.id).load() }
        }
        .confirmationDialog(
            "Block \(profile.username)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await model?.block(feedInvalidation: feedInvalidation) } }
        } message: {
            Text("You won't see each other's posts, and any follow between you ends. They won't be told.")
        }
        .deletePostConfirmation($postToDelete, isPresented: $isConfirmingDelete) { post in
            Task { await model?.delete(post, feedInvalidation: feedInvalidation) }
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isConfirmingDeleteAccount,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) { Task { await model?.deleteAccount(sessionStore) } }
        } message: {
            Text("This permanently deletes your account and every photo you've posted. This can't be undone.")
        }
    }

    // MARK: - Header, counts and actions

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model?.displayedUsername ?? profile.username)
                .font(.title2)

            if model?.isSelf == true {
                if case .signedIn(_, let email) = sessionStore.state, let email {
                    Text(email)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let relationship = model?.relationship {
                Text(ProfileModel.summary(of: relationship))
                    .foregroundStyle(.secondary)
            } else if let relationshipError = model?.relationshipError {
                Text(relationshipError)
                    .foregroundStyle(.red)
                Button("Try Again") { Task { await model(for: profile.id).load() } }
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
            countCell(model?.postCount, "posts", isEnabled: true)
            Button { listKind = .followers } label: {
                countCell(model?.followCounts?.followers, "followers", isEnabled: model?.canOpenLists == true)
            }
            .disabled(model?.canOpenLists != true)
            Button { listKind = .following } label: {
                countCell(model?.followCounts?.following, "following", isEnabled: model?.canOpenLists == true)
            }
            .disabled(model?.canOpenLists != true)
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
        if model?.isSelf == true {
            VStack(alignment: .leading, spacing: 12) {
                Button("Edit Username") { isEditingUsername = true }
                NavigationLink {
                    InvitesView()
                } label: {
                    Label("Invites", systemImage: "envelope")
                }
                Button("Log Out") { Task { await model?.signOut(sessionStore) } }
                    .disabled(model?.isSigningOut == true)
                Button("Delete Account", role: .destructive) { isConfirmingDeleteAccount = true }
                    .disabled(model?.isDeletingAccount == true)
                if model?.isDeletingAccount == true {
                    ProgressView()
                }
            }
            .padding(.horizontal)
        } else if let relationship = model?.relationship {
            HStack(spacing: 16) {
                if relationship.blocking {
                    Button("Unblock") { Task { await model?.unblock(feedInvalidation: feedInvalidation) } }
                } else {
                    Button(relationship.following ? "Unfollow" : "Follow") {
                        Task { await model?.toggleFollow(feedInvalidation: feedInvalidation) }
                    }
                    Button("Block", role: .destructive) { isConfirmingBlock = true }
                }
                Button("Report…") { reportTarget = .profile(profile) }
            }
            .buttonStyle(.bordered)
            .disabled(model?.isChanging == true)
            .padding(.horizontal)
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        if let model {
            switch model.paged.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()

            case .failed(let error):
                VStack(spacing: 8) {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await model.paged.refresh() } }
                }
                .frame(maxWidth: .infinity)
                .padding()

            case .loaded where model.paged.posts.isEmpty:
                if model.isSelf {
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
                    ForEach(model.paged.posts) { post in
                        gridCell(for: post, isSelf: model.isSelf)
                            .onAppear {
                                if post.id == model.paged.posts.last?.id {
                                    Task { await model.paged.loadMore() }
                                }
                            }
                    }
                }
                // A failed page used to land in `message` with nothing to tap;
                // the footer the feed already had is now shared (SOL-71).
                LoadMoreFooter(paged: model.paged)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    /// A square cell that opens the post. Your own cells carry the same
    /// long-press Delete the feed row has (SOL-38).
    @ViewBuilder
    private func gridCell(for post: FeedPost, isSelf: Bool) -> some View {
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
                        thumbnailSide: Self.thumbnailSide,
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

    /// The screen's model, made once and reused — unless the screen is now
    /// showing someone else, in which case the model it has is the wrong
    /// person's, and a fresh one is built.
    private func model(for profileID: UUID) -> ProfileModel {
        if let model, model.profile.id == profileID { return model }
        let newModel = ProfileModel(profile: profile, services: services, currentUserID: sessionStore.currentUserID)
        model = newModel
        return newModel
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
