import SwiftUI

/// A post's comments (SOL-90): the caption as the first row, then a flat
/// thread oldest-first, with a composer pinned to the bottom. Pushed from
/// the feed card's bubble and from `PostDetailView`; no image here, since the
/// person came from the photo. One request loads the thread, and a new
/// comment appends the row the server hands back rather than a guess.
///
/// Presentation state only (SOL-77): the draft, which profile to push, which
/// report sheet is up. `CommentsModel` owns the list and every mutation.
/// Delete is offered exactly where the delete policy would match — your own
/// comment anywhere, anything on your own post — and acts at once, with the
/// row coming back if the server refuses. Report… on someone else's comment
/// opens the account report for the commenter, then the usual block offer; a
/// comment-level report target is a later card.
struct CommentsView: View {
    let post: FeedPost

    @Environment(\.services) private var services
    @Environment(FeedInvalidation.self) private var feedInvalidation
    @Environment(EngagementStore.self) private var engagementStore
    @EnvironmentObject private var sessionStore: SessionStore

    /// Built in `.task` rather than `init`: it needs `services` and
    /// `sessionStore`, neither available there.
    @State private var model: CommentsModel?

    @State private var draft = ""
    @State private var selectedProfile: Profile?
    @State private var reportTarget: ReportSheet.Target?
    @State private var actionError: String?
    @State private var isShowingActionError = false

    /// The counter appears once this few characters are left, so the limit
    /// is a number before it is a refusal.
    private static let counterThreshold = 100

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if let model {
                    thread(model)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                composer(proxy: proxy)
            }
        }
        .background(Color.candidGround)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Comments")
                    .font(.newsreader(19))
                    .foregroundStyle(.candidInk)
            }
        }
        .toolbarBackground(Color.candidGround, for: .navigationBar)
        .navigationDestination(item: $selectedProfile) { person in
            ProfileScreen(profile: person)
        }
        .reportAndBlockFlow(target: $reportTarget) { person in
            await block(person)
        }
        .alert("Something Went Wrong", isPresented: $isShowingActionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await model(for: post).load() }
    }

    // MARK: - Thread

    @ViewBuilder
    private func thread(_ model: CommentsModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Comments", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }

        case .loaded:
            List {
                header
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.candidGround)

                if model.comments.isEmpty {
                    emptyRow
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.candidGround)
                } else {
                    ForEach(model.comments) { comment in
                        CommentRow(
                            comment: comment,
                            canDelete: model.canDelete(comment),
                            isOwn: model.isOwn(comment),
                            onOpenProfile: { selectedProfile = Profile(id: comment.authorID, username: comment.username) },
                            onDelete: { Task { await model.delete(comment, engagement: engagementStore) } },
                            onReport: { reportTarget = .profile(Profile(id: comment.authorID, username: comment.username)) }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.candidGround)
                        .id(comment.id)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// The post without its photo: who, the caption if there is one, when.
    /// The name opens the author's profile, as it does on the feed.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(username: post.username, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button {
                            selectedProfile = Profile(id: post.authorID, username: post.username)
                        } label: {
                            Text(post.username)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.candidInk)
                        }
                        .buttonStyle(.plain)
                        RelativeTimestamp(date: post.createdAt)
                            .font(.system(size: 12))
                            .foregroundStyle(.candidMuted)
                    }
                    if let caption = post.caption {
                        Text(caption)
                            .font(.newsreader(17))
                            .foregroundStyle(.candidBody)
                    }
                }
            }
            Rectangle().fill(Color.candidDivider).frame(height: 0.5)
        }
        .padding(.top, 6)
    }

    /// `EmptyState.noComments`, drawn as two lines rather than the full card,
    /// which is sized for a whole screen.
    private var emptyRow: some View {
        VStack(spacing: 6) {
            Text(EmptyState.noComments.title)
                .font(.newsreader(20))
                .foregroundStyle(.candidInk)
            Text(EmptyState.noComments.message)
                .font(.system(size: 14))
                .foregroundStyle(.candidMuted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Composer

    private func composer(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.candidDivider).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 8) {
                FormMessageSection(message: model?.message)
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Add a comment", text: $draft, axis: .vertical)
                        .font(.newsreader(17))
                        .foregroundStyle(.candidBody)
                        .tint(.candidAccent)
                        .lineLimit(1...5)
                        .disabled(model?.isSubmitting == true)
                    Button {
                        Task { await send(proxy: proxy) }
                    } label: {
                        if model?.isSubmitting == true {
                            ProgressView()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(canSend ? Color.candidAccent : Color.candidFaint)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || model?.isSubmitting == true)
                    .accessibilityLabel("Post comment")
                }
                if let remaining {
                    Text(remaining < 0 ? "\(-remaining) over the limit" : "\(remaining) left")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(remaining < 0 ? Color.red : Color.candidFaint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.candidGround)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-empty is enough to try. The limit is the service's to refuse, with
    /// a sentence, and the counter says where it is first.
    private var canSend: Bool {
        !trimmedDraft.isEmpty
    }

    /// Characters left under the limit once it is close enough to matter;
    /// negative past it. Measured the way the service and the CHECK measure.
    private var remaining: Int? {
        let left = CommentService.maxBodyLength - trimmedDraft.unicodeScalars.count
        return left <= Self.counterThreshold ? left : nil
    }

    private func send(proxy: ScrollViewProxy) async {
        guard let model, let comment = await model.add(draft, engagement: engagementStore) else { return }
        draft = ""
        // The row is appended in this same update; let it land before asking
        // the list to scroll to it.
        await Task.yield()
        withAnimation {
            proxy.scrollTo(comment.id, anchor: .bottom)
        }
    }

    /// The follow-up a report offers. A block hides both sides from each
    /// other, so the blocked person's comments leave this thread: mark the
    /// feed stale, as every block does, and reload.
    private func block(_ person: Profile) async {
        do {
            try await services.follow.block(person.id)
            feedInvalidation.markStale()
            await model?.load()
        } catch {
            actionError = error.localizedDescription
            isShowingActionError = true
        }
    }

    /// The screen's model, made once and reused.
    private func model(for post: FeedPost) -> CommentsModel {
        if let model { return model }
        let newModel = CommentsModel(post: post, services: services, currentUserID: sessionStore.currentUserID)
        model = newModel
        return newModel
    }
}

/// One comment: who, when, what they wrote — and, since SOL-91, the heart.
/// The long-press menu and the swipe offer Delete where the policy would
/// match, and Report… on anyone else's.
private struct CommentRow: View {
    let comment: Comment
    let canDelete: Bool
    let isOwn: Bool
    let onOpenProfile: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(username: comment.username, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button(action: onOpenProfile) {
                        Text(comment.username)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.candidInk)
                    }
                    .buttonStyle(.plain)
                    RelativeTimestamp(date: comment.createdAt)
                        .font(.system(size: 12))
                        .foregroundStyle(.candidMuted)
                }
                Text(comment.body)
                    .font(.newsreader(17))
                    .foregroundStyle(.candidBody)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
        .contextMenu {
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Comment", systemImage: "trash")
                }
            }
            if !isOwn {
                Button(action: onReport) {
                    Label("Report…", systemImage: "flag")
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        // Reads as one element — "carol, 2 days ago, Love this one" — with the
        // name button offered in the actions rotor, as the feed row does.
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "View profile", onOpenProfile)
    }
}

#Preview {
    NavigationStack {
        CommentsView(post: FeedPost(
            id: UUID(),
            authorID: UUID(),
            imagePath: "preview/photo.jpg",
            imageURL: nil,
            caption: "Seed post 1 from alice (followers)",
            createdAt: .now,
            username: "alice",
            visibility: .followers,
            engagement: PostEngagement(likeCount: 3, commentCount: 2, isLikedByViewer: false),
            cursor: FeedCursor(createdAt: "2026-09-04T14:04:30.909561+00:00", id: UUID())
        ))
    }
    .environmentObject(SessionStore(client: .preview))
    .environment(\.services, AppServices(client: .preview))
    .environment(FeedInvalidation())
    .environment(EngagementStore())
}
