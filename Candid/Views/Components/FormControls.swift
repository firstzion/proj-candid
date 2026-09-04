import SwiftUI

/// A submit button that swaps its label for a spinner while work is in flight.
///
/// Extracted from the sign-up and log-in screens, which had grown identical
/// copies of this. The compose screen picks it up when posting lands in SOL-11.
struct AsyncSubmitButton: View {
    let title: String
    let isSubmitting: Bool
    let isEnabled: Bool
    let action: () async -> Void

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
            Task { await action() }
        } label: {
            if isSubmitting {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .disabled(isSubmitting || !isEnabled)
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
