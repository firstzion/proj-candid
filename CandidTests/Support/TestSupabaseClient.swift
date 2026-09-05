import Foundation
import Supabase

/// A `SupabaseClient` for service tests: every request is answered by
/// `StubURLProtocol`, and auth storage is in memory rather than the Keychain.
/// No network, no live project, no persisted state between runs.
///
/// Each call to `make()` mints a random `*.example.test` host (RFC 2606) and
/// hands back both the client and a handle scoped to that host, so a test's
/// handler and recorded requests can never be seen or clobbered by another
/// test's client — including one running concurrently in another suite.
enum TestSupabaseClient {
    /// A test client plus the accessors for the `StubURLProtocol` state
    /// scoped to its own host. Use `setHandler`/`requests` here instead of
    /// calling `StubURLProtocol` directly.
    struct StubbedClient {
        let client: SupabaseClient
        let host: String

        func setHandler(_ handler: @escaping StubURLProtocol.Handler) {
            StubURLProtocol.setHandler(for: host, handler)
        }

        /// Every request this client's session has made, in order.
        var requests: [URLRequest] {
            StubURLProtocol.requests(for: host)
        }

        /// Clears the handler and recorded requests, for a test that reuses
        /// one client across several sub-cases and wants a clean slate
        /// between them.
        func reset() {
            StubURLProtocol.reset(host: host)
        }
    }

    static func make() -> StubbedClient {
        let host = "\(UUID().uuidString.lowercased()).example.test"
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!,
            supabaseKey: "test-key",
            options: SupabaseClientOptions(
                auth: .init(storage: InMemoryAuthLocalStorage()),
                global: .init(session: StubURLProtocol.session)
            )
        )
        return StubbedClient(client: client, host: host)
    }
}
