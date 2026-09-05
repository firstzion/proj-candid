import SwiftUI

/// Discovery's home under the SOL-43 decision (SOL-39): search people by
/// username, and invite a friend. Search is a prefix match on *current*
/// usernames against `searchable_profiles`, a view that leaves out you and
/// anyone you have blocked; anyone who has blocked you is already hidden by
/// the profiles policy, so both directions are excluded and a blocker's
/// account simply isn't in the list — the same silence the exact lookup
/// kept. A query that is a whole valid username with no match falls back to
/// `resolve_username`, so a friend's former handle still finds them, shown
/// with what they were called. History itself is never searchable.
struct PeopleView: View {
    @Environment(\.services) private var services

    @State private var query = ""
    @State private var results: [Profile] = []
    @State private var renamed: Renamed?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selectedProfile: Profile?

    /// A former handle that resolved to its owner's current profile.
    private struct Renamed: Hashable {
        let former: String
        let profile: Profile
    }

    /// One character would match too much of a small network to be a search.
    private static let minimumLength = 2

    private var normalizedQuery: String { UsernameRules.normalized(query) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        InvitesView()
                    } label: {
                        Label("Invite a friend", systemImage: "envelope")
                    }
                }

                if normalizedQuery.count >= Self.minimumLength {
                    Section("People") {
                        if isSearching && results.isEmpty && renamed == nil {
                            ProgressView()
                        } else if let searchError {
                            Text(searchError)
                                .foregroundStyle(.red)
                        } else if let renamed {
                            Button {
                                selectedProfile = renamed.profile
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(renamed.profile.username)
                                    Text("was @\(renamed.former)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if results.isEmpty {
                            // One of the six empty states (SOL-40), in the
                            // compact form a list row wants.
                            Text(EmptyState.searchNoResults(query: normalizedQuery).message)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(results) { person in
                                Button(person.username) { selectedProfile = person }
                            }
                        }
                    }
                }
            }
            .navigationTitle("People")
            .searchable(text: $query, prompt: "Search by username")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationDestination(item: $selectedProfile) { person in
                ProfileScreen(profile: person)
            }
            .task(id: normalizedQuery) { await search() }
        }
    }

    /// Debounced by `.task(id:)`: a keystroke cancels the previous search
    /// while it sleeps, so only a pause reaches the server.
    private func search() async {
        let prefix = normalizedQuery
        guard prefix.count >= Self.minimumLength else {
            results = []
            renamed = nil
            searchError = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }

        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            let found = try await services.profile.search(prefix: prefix)
            guard !Task.isCancelled else { return }
            results = found
            renamed = nil
            // Nothing by that prefix, but it is a whole possible username:
            // maybe it used to be someone's.
            if found.isEmpty, UsernameRules.validationProblem(prefix) == nil,
               let person = try await services.profile.profile(username: prefix),
               person.username != prefix {
                guard !Task.isCancelled else { return }
                renamed = Renamed(former: prefix, profile: person)
            }
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }
}

#Preview {
    PeopleView()
        .environmentObject(SessionStore(client: .preview))
        .environment(\.services, AppServices(client: .preview))
        .environment(FeedInvalidation())
}
