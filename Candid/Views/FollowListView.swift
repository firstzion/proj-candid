import SwiftUI

/// The people behind one of a profile's two counts. Opened only from your
/// own profile or a mutual's — the only seats from which `follows` rows for
/// that profile are readable (SOL-66). If it were ever reached from anywhere
/// else, RLS would answer with nothing, not with a leak. Each name opens that
/// person's `ProfileScreen`.
struct FollowListView: View {
    enum Kind: Hashable {
        case followers
        case following

        var title: String {
            switch self {
            case .followers: "Followers"
            case .following: "Following"
            }
        }
    }

    let profile: Profile
    let kind: Kind

    @Environment(\.services) private var services

    @State private var people: [Profile]?
    @State private var loadError: String?
    @State private var selectedProfile: Profile?

    var body: some View {
        Group {
            if let people {
                if people.isEmpty {
                    // SOL-40 writes the final copy.
                    ContentUnavailableView(
                        kind == .followers ? "No Followers Yet" : "Not Following Anyone",
                        systemImage: "person.2"
                    )
                } else {
                    List(people) { person in
                        Button(person.username) { selectedProfile = person }
                    }
                    .listStyle(.plain)
                }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedProfile) { person in
            ProfileScreen(profile: person)
        }
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            people = switch kind {
            case .followers: try await services!.follow.followers(of: profile.id)
            case .following: try await services!.follow.following(of: profile.id)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        FollowListView(profile: Profile(id: UUID(), username: "alice"), kind: .followers)
    }
    .environmentObject(SessionStore(client: .preview))
    .environment(\.services, AppServices(client: .preview))
    .environment(FeedInvalidation())
}
