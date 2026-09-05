import SwiftUI

struct RootTabView: View {
    /// Bound to the tab bar and shared downwards, so an empty state can send
    /// someone to the People tab or the Post tab (SOL-40).
    @State private var tabSelection = TabSelection()

    var body: some View {
        TabView(selection: $tabSelection.selected) {
            FeedView()
                .tabItem {
                    Label("Feed", systemImage: "photo.stack")
                }
                .tag(TabSelection.Tab.feed)

            PostView()
                .tabItem {
                    Label("Post", systemImage: "plus.square")
                }
                .tag(TabSelection.Tab.post)

            PeopleView()
                .tabItem {
                    Label("People", systemImage: "person.2")
                }
                .tag(TabSelection.Tab.people)

            ProfileTab()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(TabSelection.Tab.profile)
        }
        .environment(tabSelection)
    }
}

/// The Profile tab: the signed-in user's own `ProfileScreen`, once their
/// `profiles` row is known. Someone else's profile is the same screen, pushed
/// from wherever their name was tapped.
private struct ProfileTab: View {
    @Environment(\.services) private var services

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case loaded(Profile)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            switch phase {
            case .loading:
                ProgressView()
                    .navigationTitle("Profile")

            case .loaded(let profile):
                ProfileScreen(profile: profile)

            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Profile", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
                .navigationTitle("Profile")
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            phase = .loaded(try await services.profile.currentProfile())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(SessionStore(client: .preview))
        .environment(\.services, AppServices(client: .preview))
        .environment(FeedInvalidation())
}
