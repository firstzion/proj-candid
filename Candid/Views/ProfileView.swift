import SwiftUI

struct ProfileView: View {
    @State private var isShowingAuth = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Profile")

            // Temporary entry point so the auth screens are reachable before
            // the auth-gated app root lands in SOL-8.
            Button("Log In or Sign Up") {
                isShowingAuth = true
            }

            #if DEBUG
            BackendConnectionCheck()
            #endif
        }
        .padding()
        .sheet(isPresented: $isShowingAuth) {
            NavigationStack {
                LogInView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { isShowingAuth = false }
                        }
                    }
            }
        }
    }
}

#if DEBUG
/// Debug-only smoke test for <doc:SOL-4>: proves the app can reach the hosted
/// backend. Removed in Milestone 2 once the Profile tab shows a real account.
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
}
