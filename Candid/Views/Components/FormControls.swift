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

    private var isActionable: Bool { isEnabled && !isRunning && !isSubmitting }

    var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task {
                await action()
                isRunning = false
            }
        } label: {
            Group {
                if isSubmitting {
                    ProgressView()
                        .tint(.candidGround)
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.candidGround)
            // Disabled state is the accent at 35% opacity, not a system grey
            // (spec, Compose: "Post disabled until an image exists").
            .background(Color.candidAccent.opacity(isActionable ? 1 : 0.35))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(!isActionable)
    }
}

/// The outcome of a form's last submit, shown under its controls. One type for
/// every form: the log-in, sign-up and compose screens had each grown their
/// own enum for the same idea.
struct FormMessage: Equatable {
    enum Kind: Equatable {
        case success
        case notice
        case failure
    }

    let text: String
    let kind: Kind

    static func success(_ text: String) -> FormMessage { FormMessage(text: text, kind: .success) }
    static func notice(_ text: String) -> FormMessage { FormMessage(text: text, kind: .notice) }
    static func failure(_ text: String) -> FormMessage { FormMessage(text: text, kind: .failure) }
}

/// One 56pt label/value row with a hairline above it, for the sign-up and
/// log-in screens. The design rejects a native `Form`'s inset grey card as
/// reading "too admin" — this is the hand-rolled replacement it specs
/// instead. The label doubles as the field's accessibility label, since
/// there's no placeholder text carrying that role here.
struct HairlineField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.candidDivider).frame(height: 0.5)
            HStack(spacing: 14) {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(.candidMuted)
                    .frame(width: 92, alignment: .leading)
                content
                    .font(.system(size: 17))
                    .foregroundStyle(.candidInk)
                    .tint(.candidAccent)
                    .accessibilityLabel(label)
            }
            .frame(height: 56)
        }
    }
}

/// One hairline-bounded 54pt action row — the "Edit Username / Invites / Log
/// Out" list on a profile, and anywhere else a plain list of actions wants
/// the same look instead of a bordered button group. Consecutive rows share
/// one divider; only the first row draws one above itself too.
struct HairlineRow<Content: View>: View {
    var isFirst: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if isFirst {
                Rectangle().fill(Color.candidDivider).frame(height: 0.5)
            }
            content
                .frame(height: 54)
            Rectangle().fill(Color.candidDivider).frame(height: 0.5)
        }
    }
}

/// A form's message, shown only when there is one. Plain content rather than
/// a `Section` — none of its three call sites (sign-up, log-in, compose) sit
/// inside a `Form` anymore (the design rejects the inset grey-card look), so
/// there is no list-style chrome for a `Section` to pick up.
struct FormMessageSection: View {
    let message: FormMessage?

    var body: some View {
        if let message {
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(tint(for: message.kind))
        }
    }

    private func tint(for kind: FormMessage.Kind) -> Color {
        switch kind {
        case .success:
            return .green
        case .notice:
            return .orange
        case .failure:
            return .red
        }
    }
}
