import Foundation

/// An invite code that arrived by deep link before anyone signed up, held
/// until the sign-up form can take it (SOL-61).
///
/// `candid://invite/XXXXX-XXXXX` is the custom scheme the app already
/// registers for its auth callback, handled in the same `onOpenURL`. A
/// universal link waits for a domain; when one exists it becomes a second
/// way to set this, and nothing else changes. Because a custom-scheme link
/// is dead on a phone without the app, the share message carries the code in
/// plain text too (SOL-63).
@Observable
final class PendingInvite {
    /// Set by `CandidApp` when an invite link opens the app; `LogInView`
    /// pushes the sign-up form when it appears, and `SignUpView` moves it
    /// into its field and clears it.
    var code: String?

    /// The code in an invite link, normalised the way the database
    /// normalises it, or nil for any other URL — the auth callback included.
    static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "candid", url.host?.lowercased() == "invite" else {
            return nil
        }
        let code = InviteService.normalized(url.lastPathComponent)
        guard !code.isEmpty, code != "/" else { return nil }
        return code
    }
}
