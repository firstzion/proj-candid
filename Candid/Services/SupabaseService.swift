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
final class SupabaseService {
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

        guard let url = URL(string: "https://\(host)"), url.host != nil else {
            throw SupabaseConfigurationError.malformedHost(host)
        }

        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }

    private static func requiredString(forKey key: String, in bundle: Bundle) throws -> String {
        let value = bundle.object(forInfoDictionaryKey: key) as? String
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupabaseConfigurationError.missingValue(key: key)
        }
        return value
    }
}
