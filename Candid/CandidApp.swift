import SwiftUI

@main
struct CandidApp: App {
    @StateObject private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessionStore)
                .task { sessionStore.start() }
        }
    }
}
