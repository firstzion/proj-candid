import SwiftUI

/// A submit button that swaps its label for a spinner while work is in flight.
///
/// Extracted from the sign-up and log-in screens, which had grown identical
/// copies of this; the compose screen uses it too.
struct AsyncSubmitButton: View {
    let title: String
    let isSubmitting: Bool
    let isEnabled: Bool
    let action: () async -> Void

    /// Set synchronously in the tap handler. The caller's `isSubmitting` only
    /// flips once its action has started running, and two quick taps could
    /// both enqueue a submission in that gap.
    @State private var isRunning = false

    init(
        _ title: String,
        isSubmitting: Bool,
        isEnabled: Bool = true,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.isSubmitting = isSubmitting
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task {
                await action()
                isRunning = false
            }
        } label: {
            if isSubmitting {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .disabled(isRunning || isSubmitting || !isEnabled)
    }
}

/// A form section carrying a single message, shown only when there is one.
struct FormMessageSection: View {
    let message: String?
    var tint: Color = .red

    var body: some View {
        if let message {
            Section {
                Text(message).foregroundStyle(tint)
            }
        }
    }
}
