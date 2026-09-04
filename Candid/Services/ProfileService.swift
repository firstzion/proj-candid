import Foundation
import Supabase

enum ProfileError: LocalizedError {
    case notSignedIn
    case profileMissing
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You're not signed in."
        case .profileMissing:
            return "No profile found for this account."
        case .other(let message):
            return message
        }
    }
}

struct ProfileService {
    /// Loads the signed-in user's own `profiles` row.
    ///
    /// Reads `auth.session` rather than `currentSession` so an expired access
    /// token is refreshed before the query, instead of failing under RLS.
    func currentProfile() async throws -> Profile {
        let client = try SupabaseService.shared.client()

        let userID: UUID
        do {
            userID = try await client.auth.session.user.id
        } catch {
            throw ProfileError.notSignedIn
        }

        do {
            return try await client
                .from("profiles")
                .select()
                .eq("id", value: userID)
                .single()
                .execute()
                .value
        } catch {
            throw Self.mapProfileError(error)
        }
    }

    static func mapProfileError(_ error: Error) -> ProfileError {
        guard let postgrestError = error as? PostgrestError else {
            return .other(error.localizedDescription)
        }

        // PostgREST returns PGRST116 when `.single()` matches no rows, which
        // here means either the trigger did not provision a profile or RLS
        // hid it.
        if postgrestError.code == "PGRST116" {
            return .profileMissing
        }

        // PostgrestError does not conform to LocalizedError, so its
        // localizedDescription is a generic bridged string with none of the
        // server's detail in it. Use the server's own message.
        return .other(postgrestError.message)
    }
}
