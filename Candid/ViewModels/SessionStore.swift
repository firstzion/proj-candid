import Foundation
import Supabase

/// Single source of truth for whether someone is logged in.
///
/// The Supabase SDK owns session persistence and refresh — sessions live in the
/// Keychain (`KeychainLocalStorage`) and refresh themselves
/// (`autoRefreshToken`). This type builds none of that; it mirrors what the SDK
/// reports so SwiftUI can react to it.
///
/// `authStateChanges` emits `.initialSession` as soon as it is subscribed to,
/// carrying whatever was restored from the Keychain — even a session whose
/// access token has already expired; `SupabaseService` opts into that with
/// `emitLocalSessionAsInitialSession`. That first event is what decides, on
/// launch, between the auth screens and the main tabs.
///
/// An expired restored session still counts as signed in. The SDK refreshes
/// it in the background, and every request that goes through `auth.session`
/// refreshes first anyway. A refresh the server definitively rejects — a
/// revoked or already-rotated refresh token — makes the SDK clear the Keychain
/// and emit `.signedOut`, which lands here like any other sign-out. Only a nil
/// session means nobody is signed in; a mere network failure never produces
/// one.
@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(email: String?)
    }

    @Published private(set) var state: State = .loading

    /// Mirrors the SDK's auth state for as long as the calling task lives.
    ///
    /// Run from `.task` on the root view: that task lasts the life of the
    /// scene and is cancelled with it, which makes the observation structured
    /// — no stored `Task` to clear on every exit path, no `deinit` to cancel
    /// it, and SwiftUI restarts it if the root view is ever re-created. The
    /// previous shape spawned an unstructured `Task` from inside `.task`
    /// precisely to escape that lifetime, which read as a bug rather than a
    /// decision.
    func observe() async {
        guard let client = try? SupabaseService.shared.client() else {
            // Misconfigured build: treat as signed out so the app still
            // renders. The config error surfaces on the first auth attempt.
            update(from: nil)
            return
        }

        // `AsyncStream` ends its iteration when the task is cancelled, so
        // cancellation needs no check of its own.
        for await (_, session) in client.auth.authStateChanges {
            update(from: session)
        }
    }

    /// Publishes only on a real change. `@Published` fires on every
    /// assignment, so without the check each hourly `.tokenRefreshed`
    /// re-published an identical state and re-evaluated `RootView.body` for
    /// nothing. Every event maps the same way: a session means signed in —
    /// even an expired one, which the SDK is refreshing — and nil means
    /// signed out.
    private func update(from session: Session?) {
        let newState: State = session.map { .signedIn(email: $0.user.email) } ?? .signedOut
        if newState != state {
            state = newState
        }
    }

    /// Signs out and lets the auth-state stream drive the UI back to Log In.
    ///
    /// The SDK clears the local session and emits `.signedOut` before calling
    /// the server, so this takes effect even when the network call fails.
    func signOut() async throws {
        let client = try SupabaseService.shared.client()
        try await client.auth.signOut()
    }
}
