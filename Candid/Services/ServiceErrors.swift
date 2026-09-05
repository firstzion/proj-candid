import Foundation
import OSLog
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

/// Whether this is a Debug build. Exists as a value rather than only as an
/// `#if` so `fallbackMessage` can take it as a parameter, which is what lets
/// one test run reach both wordings — a `#if` inside the function body would
/// leave whichever branch CI is not building untested.
#if DEBUG
let isDebugBuild = true
#else
let isDebugBuild = false
#endif

/// What to show for a failure no mapper recognised: our sentence on screen,
/// the server's words in the log.
///
/// Every service's error enum ends in an `.other(String)` whose
/// `errorDescription` a view puts straight on screen. Until now that string
/// was `serverMessage(of:)`, so "permission denied for table posts",
/// "JSON object requested, multiple (or no) rows returned" and
/// "function public.username_available(text) does not exist" were all things
/// a person could be shown. None of them is actionable by the person reading
/// it, and each describes our mistake in our vocabulary. The detail is still
/// worth having — to us — so it goes to the log under a `context` naming the
/// mapper it fell through, and the screen gets one sentence.
///
/// The mapped cases are untouched: `notPermitted`, `usernameTaken`,
/// `quotaReached`, the invite states and the rest are already worded for the
/// person, and `SignUpError.weakPassword` deliberately carries the server's
/// own explanation of the password policy, which we must not reword.
///
/// - Parameters:
///   - context: the mapper that fell through, as a literal. Combined with the
///     detail it is enough to find the call: a service has at most a couple of
///     fall-through points and they fail in different words.
///   - includeDetail: whether to append the server's words to the sentence.
///     Debug builds do, so a failure is diagnosable without opening Console;
///     Release builds do not.
func fallbackMessage(
    for error: Error,
    context: StaticString,
    includeDetail: Bool = isDebugBuild
) -> String {
    let detail = serverMessage(of: error)
    Log.services.error("\(context, privacy: .public): \(detail, privacy: .public)")

    // The one failure the person can actually do something about, so it says
    // so instead of being folded into "something went wrong".
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "You're offline. Check your connection and try again."
        case .timedOut:
            return "That took too long. Try again."
        default:
            break
        }
    }

    return includeDetail ? "Something went wrong (\(detail))" : "Something went wrong. Try again."
}
