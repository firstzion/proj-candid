import Foundation
import Supabase

/// A `SupabaseClient` for service tests: every request is answered by
/// `StubURLProtocol`, and auth storage is in memory rather than the Keychain.
/// No network, no live project, no persisted state between runs.
enum TestSupabaseClient {
    static func make() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "test-key",
            options: SupabaseClientOptions(
                auth: .init(storage: InMemoryAuthLocalStorage()),
                global: .init(session: StubURLProtocol.session)
            )
        )
    }
}
