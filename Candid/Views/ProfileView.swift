import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.services) private var services

    @State private var profileState: ProfileState = .loading
    @State private var isSigningOut = false
    @State private var signOutError: String?

    @State private var isShowingDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?

    /// "Find people": the username typed, the lookup in flight, its outcome,
    /// and the profile it found — non-nil pushes `UserProfileView`.
    @State private var lookupUsername = ""
    @State private var isLookingUp = false
    @State private var lookupMessage: FormMessage?
    @State private var foundProfile: Profile?

    private enum ProfileState {
        case loading
        case loaded(Profile)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch profileState {
                case .loading:
                    ProgressView()

                case .loaded(let profile):
                    VStack(spacing: 4) {
                        Text(profile.username)
                            .font(.title2)

                        if case .signedIn(_, let email) = sessionStore.state, let email {
                            Text(email)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                case .failed(let message):
                    VStack(spacing: 8) {
                        Text(message)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)

                        Button("Try Again") {
                            Task { await loadProfile() }
                        }
                    }
                }

                findPeople

                Button("Log Out") {
                    Task { await signOut() }
                }
                .disabled(isSigningOut)

                if let signOutError {
                    Text(signOutError)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button("Delete Account", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
                .disabled(isDeletingAccount)

                if isDeletingAccount {
                    ProgressView()
                }

                if let deleteAccountError {
                    Text(deleteAccountError)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Profile")
            .navigationDestination(item: $foundProfile) { profile in
                UserProfileView(profile: profile)
            }
            .task { await loadProfile() }
            .confirmationDialog(
                "Delete your account?",
                isPresented: $isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text("This permanently deletes your account and every photo you've posted. This can't be undone.")
            }
        }
    }

    /// Lookup by exact username — the smallest path from "signed up" to
    /// "following someone" while there is no search (SOL-39), and the only
    /// way to reach a stranger, since the feed shows only people you already
    /// follow. Someone who has blocked you is hidden by the profiles read
    /// policy and answers exactly like a typo.
    private var findPeople: some View {
        VStack(spacing: 8) {
            Text("Find people")
                .font(.headline)

            HStack {
                TextField("Username", text: $lookupUsername)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        guard canLookUp else { return }
                        Task { await lookUp() }
                    }

                AsyncSubmitButton("Find", isSubmitting: isLookingUp, isEnabled: canLookUp) {
                    await lookUp()
                }
            }

            if let lookupMessage {
                Text(lookupMessage.text)
                    .font(.footnote)
                    .foregroundStyle(lookupMessage.kind == .failure ? Color.red : Color.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Trims what the lookup trims, so the button and the request agree on
    /// what counts as blank.
    private var canLookUp: Bool {
        !UsernameRules.normalized(lookupUsername).isEmpty
    }

    private func lookUp() async {
        isLookingUp = true
        lookupMessage = nil
        defer { isLookingUp = false }

        do {
            if let profile = try await services!.profile.profile(username: lookupUsername) {
                foundProfile = profile
            } else {
                // A typo, a name nobody has, or someone who has blocked you —
                // deliberately the same answer for all three.
                lookupMessage = .notice("No one by that name.")
            }
        } catch {
            lookupMessage = .failure(error.localizedDescription)
        }
    }

    private func loadProfile() async {
        profileState = .loading
        do {
            profileState = .loaded(try await services!.profile.currentProfile())
        } catch {
            profileState = .failed(error.localizedDescription)
        }
    }

    private func signOut() async {
        isSigningOut = true
        signOutError = nil

        do {
            try await sessionStore.signOut()
        } catch {
            // The SDK clears the local session before calling the server, so
            // the app is already signed out; this only reports that the
            // server-side token revocation did not go through.
            signOutError = "Signed out on this device, but the server call failed: \(error.localizedDescription)"
        }

        isSigningOut = false
    }

    /// Deletes the account, then signs out through `SessionStore` exactly
    /// like the "Log Out" button — the SDK's auth-state stream carries the
    /// app back to the Log In screen either way.
    private func deleteAccount() async {
        isDeletingAccount = true
        deleteAccountError = nil

        do {
            try await services!.profile.deleteAccount()
            try await sessionStore.signOut()
        } catch {
            deleteAccountError = error.localizedDescription
        }

        isDeletingAccount = false
    }
}

#Preview {
    ProfileView()
        .environmentObject(SessionStore(client: .preview))
        .environment(\.services, AppServices(client: .preview))
        .environment(FeedInvalidation())
}
