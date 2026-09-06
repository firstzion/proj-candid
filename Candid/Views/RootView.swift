import SwiftUI

/// Chooses between the auth screens and the main app based on session state.
struct RootView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    /// The switcher lives on Profile; this is what actually applies it,
    /// however signed-in state changes underneath it.
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    var body: some View {
        Group {
            switch sessionStore.state {
            case .loading:
                ProgressView()

            case .signedOut:
                NavigationStack {
                    LogInView()
                }

            case .signedIn:
                RootTabView()
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
    }
}
