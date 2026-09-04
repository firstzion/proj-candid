import SwiftUI

/// Chooses between the auth screens and the main app based on session state.
struct RootView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
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
}
