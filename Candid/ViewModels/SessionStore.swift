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
/// carrying whatever was restored from the Keychain. That first event is what
/// decides, on launch, between the auth screens and the main tabs.
@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(email: String?)
    }

    @Published private(set) var state: State = .loading

    private var observationTask: Task<Void, Never>?

    /// Starts mirroring the SDK's auth state. Safe to call more than once.
    func start() {
        guard observationTask == nil else { return }

        observationTask = Task { [weak self] in
            guard let client = try? SupabaseService.shared.client() else {
                // Misconfigured build: treat as signed out so the app still
                // renders. The config error surfaces on the first auth attempt.
                self?.state = .signedOut
                return
            }

            for await (_, session) in client.auth.authStateChanges {
                if Task.isCancelled { return }
                self?.state = session.map { .signedIn(email: $0.user.email) } ?? .signedOut
            }
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

    deinit {
        observationTask?.cancel()
    }
}
