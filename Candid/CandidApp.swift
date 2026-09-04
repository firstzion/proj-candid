import Supabase
import SwiftUI

@main
struct CandidApp: App {
    private let launchState: LaunchState

    /// Resolved once, at launch, from `Info.plist` via `SupabaseService`. A
    /// client that fails to build shows a configuration-error screen instead
    /// of `RootView` — see `ConfiguredRootScene` and `ConfigurationErrorView`
    /// — so nothing below the app root needs to handle that case, and no
    /// service method needs a `try` for it.
    enum LaunchState {
        case configured(AppServices, SupabaseClient)
        case misconfigured(Error)
    }

    init() {
        do {
            let client = try SupabaseService.shared.client()
            launchState = .configured(AppServices(client: client), client)
        } catch {
            launchState = .misconfigured(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch launchState {
            case .configured(let services, let client):
                ConfiguredRootScene(services: services, client: client)
            case .misconfigured(let error):
                ConfigurationErrorView(error: error)
            }
        }
    }
}

/// The app once configuration is known good: builds the one `SessionStore`
/// from the live client and wires both it and `AppServices` into the
/// environment for everything under `RootView`.
private struct ConfiguredRootScene: View {
    let services: AppServices
    let client: SupabaseClient

    @StateObject private var sessionStore: SessionStore
    @State private var feedInvalidation = FeedInvalidation()

    init(services: AppServices, client: SupabaseClient) {
        self.services = services
        self.client = client
        _sessionStore = StateObject(wrappedValue: SessionStore(client: client))
    }

    var body: some View {
        RootView()
            .environmentObject(sessionStore)
            .environment(\.services, services)
            .environment(feedInvalidation)
            .task { await sessionStore.observe() }
            .onOpenURL { url in
                Task { await handleAuthCallback(url) }
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
        _ = try? await client.auth.session(from: url)
    }
}
