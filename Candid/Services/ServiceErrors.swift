import Foundation
import Supabase

/// The one rule every service applies to a failure from reading the
/// signed-in user's session — `auth.session`, called fresh before most
/// requests so an expired access token is refreshed rather than failing
/// under RLS.
///
/// Distinguishes "nobody is signed in" from "signed in, but the session
/// could not be refreshed just now" — typically no network. Both used to
/// come out as `.notSignedIn` in every service, contradicting the tabs the
/// person was looking at. Only a genuinely missing session means not signed
/// in; that includes one the server has revoked, which the SDK reports the
/// same way after clearing it locally.
enum SessionFailure {
    static func isMissingSession(_ error: Error) -> Bool {
        (error as? AuthError)?.errorCode == .sessionNotFound
    }
}

/// The server's own words for a failure. `PostgrestError` and `StorageError`
/// are plain `Error`s, not `LocalizedError`s, so `localizedDescription` on
/// either is generic Foundation boilerplate with none of the server's
/// detail — read `message` instead, which is what every service's error
/// mapper falls back to.
func serverMessage(of error: Error) -> String {
    if let postgrestError = error as? PostgrestError { return postgrestError.message }
    if let storageError = error as? StorageError { return storageError.message }
    return error.localizedDescription
}
