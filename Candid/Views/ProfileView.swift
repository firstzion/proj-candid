import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var profileState: ProfileState = .loading
    @State private var isSigningOut = false
    @State private var signOutError: String?

    @State private var isShowingDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?

    private enum ProfileState {
        case loading
        case loaded(Profile)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 24) {
            switch profileState {
            case .loading:
                ProgressView()

            case .loaded(let profile):
                VStack(spacing: 4) {
                    Text(profile.username)
                        .font(.title2)

                    if case .signedIn(let email) = sessionStore.state, let email {
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

    private func loadProfile() async {
        profileState = .loading
        do {
            profileState = .loaded(try await ProfileService().currentProfile())
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
            try await ProfileService().deleteAccount()
            try await sessionStore.signOut()
        } catch {
            deleteAccountError = error.localizedDescription
        }

        isDeletingAccount = false
    }
}

#Preview {
    ProfileView()
        .environmentObject(SessionStore())
}
