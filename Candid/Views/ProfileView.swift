import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    @State private var isSigningOut = false
    @State private var signOutError: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Profile")

            if case .signedIn(let email) = sessionStore.state {
                Text(email ?? "Signed in")
                    .foregroundStyle(.secondary)
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

            #if DEBUG
            BackendConnectionCheck()
            #endif
        }
        .padding()
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
}

#if DEBUG
/// Debug-only smoke test from SOL-4: proves the app can reach the hosted
/// backend. Replaced by real account content in SOL-8.
private struct BackendConnectionCheck: View {
    private enum State {
        case idle
        case checking
        case succeeded(postCount: Int)
        case failed(String)
    }

    private struct PostRow: Decodable {
        let id: UUID
    }

    @SwiftUI.State private var state: State = .idle

    var body: some View {
        VStack(spacing: 12) {
            Button("Test Backend Connection") {
                Task { await runCheck() }
            }
            .disabled(isChecking)

            switch state {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView()
            case .succeeded(let count):
                Text("Connected. `posts` returned \(count) row\(count == 1 ? "" : "s").")
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    private func runCheck() async {
        state = .checking
        do {
            let client = try SupabaseService.shared.client()
            let rows: [PostRow] = try await client
                .from("posts")
                .select("id")
                .execute()
                .value
            state = .succeeded(postCount: rows.count)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
#endif

#Preview {
    ProfileView()
        .environmentObject(SessionStore())
}
