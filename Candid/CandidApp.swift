import SwiftUI

@main
struct CandidApp: App {
    @StateObject private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessionStore)
                .task { await sessionStore.observe() }
                .onOpenURL { url in
                    Task { await handleAuthCallback(url) }
                }
        }
    }

    /// Completes email confirmation / password reset / magic-link sign-in.
    ///
    /// The `candid://auth-callback` link from a Supabase auth email lands
    /// here; `session(from:)` parses the tokens out of it and establishes the
    /// session, which `SessionStore`'s `authStateChanges` subscription then
    /// picks up like any other sign-in. A failure here just means the link
    /// was stale or already used — nothing to surface, the person can retry
    /// from the app.
    private func handleAuthCallback(_ url: URL) async {
        guard let client = try? SupabaseService.shared.client() else { return }
        _ = try? await client.auth.session(from: url)
    }
}
