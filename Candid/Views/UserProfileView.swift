import SwiftUI

/// Another person's profile, as thin as it can be while the graph is being
/// built: who they are, where you stand with each other, and the controls
/// that change that — Follow / Unfollow and Block / Unblock. Reached by
/// tapping a username in the feed or looking one up on the Profile tab.
/// Counts and a post grid arrive with SOL-37.
///
/// Every control is optimistic: the relationship line and the button change
/// the moment they are tapped, and change back with a message if the request
/// fails. Every success marks the feed stale (`FeedInvalidation`), because
/// each of these actions changes which rows the database will hand back.
///
/// Nothing here decides what a follow or a block *means*. The database
/// severs follows when a block is made and hides posts accordingly; this
/// screen only writes the row and shows what it read back.
struct UserProfileView: View {
    let profile: Profile

    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation
    @EnvironmentObject private var sessionStore: SessionStore

    /// Nil until loaded. Every action below replaces it optimistically and
    /// restores the previous value on failure.
    @State private var relationship: Relationship?
    @State private var loadError: String?
    @State private var isChanging = false
    @State private var message: FormMessage?
    @State private var isConfirmingBlock = false

    /// Looking at yourself: no relationship to show, nothing to change.
    private var isSelf: Bool { sessionStore.currentUserID == profile.id }

    var body: some View {
        Form {
            Section {
                Text(profile.username)
                    .font(.title2)

                if isSelf {
                    Text("This is you")
                        .foregroundStyle(.secondary)
                } else if let relationship {
                    Text(Self.summary(of: relationship))
                        .foregroundStyle(.secondary)
                } else if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                    Button("Try Again") { Task { await load() } }
                } else {
                    ProgressView()
                }
            }

            if !isSelf, let relationship {
                Section {
                    if relationship.blocking {
                        Button("Unblock") { Task { await unblock() } }
                    } else {
                        Button(relationship.following ? "Unfollow" : "Follow") {
                            Task { await toggleFollow() }
                        }
                        Button("Block", role: .destructive) { isConfirmingBlock = true }
                    }
                }
                .disabled(isChanging)
            }

            FormMessageSection(message: message)
        }
        .navigationTitle(profile.username)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: profile.id) { await load() }
        .confirmationDialog(
            "Block \(profile.username)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await block() } }
        } message: {
            Text("You won't see each other's posts, and any follow between you ends. They won't be told.")
        }
    }

    /// The relationship in the app's words. "Friends" is a mutual follow —
    /// the same derivation as the `mutuals` view, on the two rows that matter.
    static func summary(of relationship: Relationship) -> String {
        if relationship.blocking { return "Blocked" }
        if relationship.isMutual { return "Friends" }
        if relationship.following { return "Following" }
        if relationship.followedBy { return "Follows you" }
        return "Not following"
    }

    private func load() async {
        guard !isSelf else { return }
        loadError = nil
        do {
            relationship = try await services!.follow.relationship(with: profile.id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Flips `following` at once and asks the server to agree; a failure
    /// flips it back and says why.
    private func toggleFollow() async {
        guard let previous = relationship else { return }
        var optimistic = previous
        optimistic.following.toggle()
        let wantsToFollow = optimistic.following

        await change(to: optimistic, rollingBackTo: previous) {
            if wantsToFollow {
                try await services!.follow.follow(profile.id)
            } else {
                try await services!.follow.unfollow(profile.id)
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
            try await services!.follow.block(profile.id)
        }
    }

    /// Unblocking restores nothing — no edge comes back — so the state after
    /// it is "not following", from scratch.
    private func unblock() async {
        guard let previous = relationship else { return }
        await change(to: .unconnected, rollingBackTo: previous) {
            try await services!.follow.unblock(profile.id)
        }
    }

    /// The one shape every action takes: show the intended state, make the
    /// request, and either mark the feed stale or put the old state back
    /// with a message.
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
            // What the feed should show has changed; see FeedInvalidation.
            feedInvalidation.markStale()
        } catch {
            relationship = previous
            message = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        UserProfileView(profile: Profile(id: UUID(), username: "alice"))
    }
    .environmentObject(SessionStore(client: .preview))
    .environment(\.services, AppServices(client: .preview))
    .environment(FeedInvalidation())
}
