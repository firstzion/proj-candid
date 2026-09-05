import SwiftUI

private struct ReportAndBlockFlowModifier: ViewModifier {
    @Binding var target: ReportSheet.Target?
    let offerBlock: Bool
    let onBlock: (Profile) async -> Void

    @State private var reported: Profile?
    @State private var isOfferingBlock = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $target) { target in
                ReportSheet(target: target) { person in
                    reported = person
                    // No review queue exists yet, so the reporter usually
                    // wants the content gone from their own view now — unless
                    // the caller already knows the account is blocked.
                    if offerBlock {
                        isOfferingBlock = true
                    }
                }
            }
            .confirmationDialog(
                "Reported. Block them too?",
                isPresented: $isOfferingBlock,
                titleVisibility: .visible,
                presenting: reported
            ) { person in
                Button("Block @\(person.username)", role: .destructive) {
                    Task { await onBlock(person) }
                }
                Button("Not Now", role: .cancel) {}
            } message: { _ in
                Text("No review queue exists yet, so blocking is how to stop seeing their posts now. You won't see each other's posts, and any follow between you ends. They won't be told.")
            }
    }
}

extension View {
    /// Report a post or a person (SOL-42), then offer a block (one copy of the
    /// wording, the fuller one). `onBlock` is the caller's block: the feed and
    /// the detail view call `FollowService.block` and mark the feed stale; the
    /// profile routes through its optimistic `change(to:rollingBackTo:)`.
    /// `offerBlock` skips the follow-up dialog — the profile passes `false`
    /// when it already knows the account is blocked.
    func reportAndBlockFlow(
        target: Binding<ReportSheet.Target?>,
        offerBlock: Bool = true,
        onBlock: @escaping (Profile) async -> Void
    ) -> some View {
        modifier(ReportAndBlockFlowModifier(target: target, offerBlock: offerBlock, onBlock: onBlock))
    }
}
