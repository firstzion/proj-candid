import Foundation
import Supabase

enum SupabaseConfigurationError: LocalizedError {
    case missingValue(key: String)
    case malformedHost(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let key):
            return """
                \(key) is missing from the app's Info.plist. Copy \
                Config/Secrets.example.xcconfig to Config/Secrets.xcconfig, \
                fill in the project's values, and rebuild.
                """
        case .malformedHost(let host):
            return "Could not build a valid Supabase URL from host \"\(host)\"."
        }
    }
}

/// Vends the app's single Supabase client.
///
/// Credentials come from `Config/Secrets.xcconfig` (gitignored) by way of the
/// partial `Config/Info.plist`. Only the API host is stored, never the full
/// URL: xcconfig treats `//` as the start of a comment, so an `https://` value
/// would be silently truncated. The scheme is prepended here instead.
///
/// Configuration is resolved once at init and the outcome kept, so a missing or
/// malformed config surfaces as a thrown error at the call site rather than a
/// crash on launch.
///
/// `@unchecked Sendable`: `clientResult` is a `let`, written once by `init`
/// and never mutated again, so concurrent reads of `shared` are safe. The
/// compiler can't verify that on its own — `Result<SupabaseClient, Error>`
/// isn't provably `Sendable`, since the boxed `Error` existential isn't —
/// which is exactly what strict concurrency checking flagged here.
final class SupabaseService: @unchecked Sendable {
    static let shared = SupabaseService()

    private let clientResult: Result<SupabaseClient, Error>

    init(bundle: Bundle = .main) {
        clientResult = Result { try Self.makeClient(bundle: bundle) }
    }

    func client() throws -> SupabaseClient {
        try clientResult.get()
    }

    private static func makeClient(bundle: Bundle) throws -> SupabaseClient {
        let host = try requiredString(forKey: "SUPABASE_API_HOST", in: bundle)
        let key = try requiredString(forKey: "SUPABASE_PUBLISHABLE_KEY", in: bundle)

        // Loopback only, never a real host: `supabase start`'s local stack
        // serves plain HTTP, and ATS exempts loopback addresses regardless.
        // This is what lets manual QA (SOL-67) point Secrets.xcconfig at a
        // local instance and use throwaway seeded accounts, now that seeding
        // the hosted project is permanently off the table (SOL-86).
        let isLoopback = host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost")
        let scheme = isLoopback ? "http" : "https"

        guard let url = URL(string: "\(scheme)://\(host)"), url.host != nil else {
            throw SupabaseConfigurationError.malformedHost(host)
        }

        // Report the Keychain session as the initial auth event even when its
        // access token has expired, and let the SDK refresh it in the
        // background. The SDK's legacy default (`false`) attempts the refresh
        // *first* and reports no session at all if that fails — so someone
        // launching offline, or on a slow network, with a token more than an
        // hour old was shown the Log In screen while still signed in, then
        // bounced into the app once the auto-refresh got through. The SDK
        // flags the legacy behaviour as a runtime issue and will flip the
        // default in its next major release.
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
    }

    private static func requiredString(forKey key: String, in bundle: Bundle) throws -> String {
        let value = (bundle.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            throw SupabaseConfigurationError.missingValue(key: key)
        }
        // The trimmed value, not the raw one. This used to check the trimmed
        // string but return the original, so a stray space after the host in
        // Secrets.xcconfig would have become part of the URL.
        return value
    }
}

extension SupabaseClient {
    /// A non-functional client for SwiftUI `#Preview`s, which have no launch
    /// sequence to resolve `Info.plist` and build a real one. Constructing a
    /// client does no I/O by itself, so this is safe to use freely; any
    /// service call made through it simply fails, same as a preview with no
    /// session already does today, landing in that view's existing error
    /// state rather than crashing.
    static let preview = SupabaseClient(
        supabaseURL: URL(string: "https://example.supabase.co")!,
        supabaseKey: "preview"
    )
}
