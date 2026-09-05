import SwiftUI

private struct DeletePostConfirmationModifier: ViewModifier {
    @Binding var post: FeedPost?
    @Binding var isPresented: Bool
    let onConfirm: (FeedPost) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete this post?",
            isPresented: $isPresented,
            titleVisibility: .visible,
            presenting: post
        ) { post in
            Button("Delete Post", role: .destructive) {
                onConfirm(post)
            }
        } message: { _ in
            Text("The photo is removed for everyone who could see it. This can't be undone.")
        }
    }
}

extension View {
    /// The one "Delete this post?" dialog (SOL-38), with its one message —
    /// used from the feed, the profile grid and the detail view. The detail
    /// view, which always means its own post, passes `.constant(post)`.
    func deletePostConfirmation(
        _ post: Binding<FeedPost?>,
        isPresented: Binding<Bool>,
        onConfirm: @escaping (FeedPost) -> Void
    ) -> some View {
        modifier(DeletePostConfirmationModifier(post: post, isPresented: isPresented, onConfirm: onConfirm))
    }
}
