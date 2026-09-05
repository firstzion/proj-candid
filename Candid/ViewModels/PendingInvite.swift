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
///
/// Two cases, both handled in `CandidApp`'s `onOpenURL` (SOL-76): signed
/// out, the code is held here exactly as before. Signed in, there is no
/// sign-up form to fill — `LogInView` isn't even mounted — so the code is
/// never set in the first place; and if a code from an earlier tap is still
/// sitting here when a sign-in happens (logged in rather than signed up
/// with), it is cleared then, so it can never resurface at the next
/// sign-out as a stale code on someone else's session.
@Observable
final class PendingInvite {
    /// Set by `CandidApp` when an invite link opens the app while signed
    /// out; `LogInView` pushes the sign-up form when it appears, and
    /// `SignUpView` moves it into its field and clears it.
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

    /// Whether an invite code just received by deep link should be held
    /// (SOL-76): only while signed out, since signed in there is no sign-up
    /// form for it to reach. Pulled out of `CandidApp.onOpenURL` as its own
    /// pure function so the one bit of policy in this class has a test that
    /// does not need a view.
    static func shouldHold(isSignedIn: Bool) -> Bool {
        !isSignedIn
    }
}
