import Foundation
import Supabase

/// Errors surfaced to the sign-up screen.
///
/// Supabase returns these as opaque API errors, so they are recognised by
/// message rather than by a typed code.
enum SignUpError: LocalizedError {
    case emailAlreadyRegistered
    case usernameTaken
    case invalidUsername(String)
    case invalidEmail
    case weakPassword(String)
    case accountCreationFailed
    case other(String)

    var errorDescription: String? {
        switch self {
        case .emailAlreadyRegistered:
            return "An account with that email already exists."
        case .usernameTaken:
            return "That username is already taken. Try another one."
        case .invalidUsername(let problem):
            // Wording comes from `UsernameRules`, which knows what is wrong.
            return problem
        case .invalidEmail:
            return "That email address doesn't look valid."
        case .weakPassword(let detail):
            return detail
        case .accountCreationFailed:
            // GoTrue's sanitised "Database error saving new user" — see
            // `mapSignUpError`. With the format validated and availability
            // checked first, this is either a lost race for the username or a
            // genuine server-side failure; the wording leaves both open rather
            // than asserting the username was taken.
            return "The account couldn't be created. That username may have just been taken — try another, or try again in a moment."
        case .other(let message):
            return message
        }
    }
}

/// Errors surfaced to the log-in screen.
enum SignInError: LocalizedError {
    case invalidCredentials
    case emailNotConfirmed
    case other(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            // Supabase deliberately returns the same error for an unknown email
            // and a wrong password, so callers cannot probe for registered
            // addresses. The wording keeps that ambiguity.
            return "That email or password is incorrect."
        case .emailNotConfirmed:
            return "That account hasn't confirmed its email address yet."
        case .other(let message):
            return message
        }
    }
}

struct SignUpResult {
    let userID: UUID
    /// False when the project still requires email confirmation, in which case
    /// the account exists but is not usable until the link is clicked.
    let hasActiveSession: Bool
}

struct AuthService {
    func signUp(email: String, password: String, username: String) async throws -> SignUpResult {
        let client = try SupabaseService.shared.client()
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = UsernameRules.normalized(username)

        // Say precisely what is wrong before any request. The database enforces
        // the same rules, but a CHECK failure inside the sign-up trigger comes
        // back as GoTrue's sanitised "Database error saving new user".
        if let problem = UsernameRules.validationProblem(username) {
            throw SignUpError.invalidUsername(problem)
        }

        // Ask before creating the auth user, for the same reason: a duplicate
        // that fails inside the trigger is unrecognisable by the time it gets
        // here. Advisory only — see `isUsernameAvailable`.
        guard try await isUsernameAvailable(username, client: client) else {
            throw SignUpError.usernameTaken
        }

        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["username": .string(username)]
            )
            return SignUpResult(
                userID: response.user.id,
                hasActiveSession: response.session != nil
            )
        } catch {
            throw Self.mapSignUpError(error)
        }
    }

    /// Asks the database whether `username` can still be claimed, through the
    /// `username_available` function. The person asking has no session yet,
    /// and `profiles` is readable only by `authenticated`, so a plain query
    /// would see nothing; the function runs as its definer and returns one
    /// bit.
    ///
    /// The answer is advisory. Two people can be told "free" at the same
    /// moment and one of them then loses the race inside the sign-up trigger;
    /// `mapSignUpError` words that outcome as a possibly-taken username rather
    /// than asserting it.
    private func isUsernameAvailable(_ username: String, client: SupabaseClient) async throws -> Bool {
        do {
            return try await client
                .rpc("username_available", params: ["candidate": username])
                .execute()
                .value
        } catch {
            throw Self.mapSignUpError(error)
        }
    }

    /// Signs in. Deliberately returns nothing: `SessionStore` is the single
    /// source of truth for who is signed in, and the SDK's auth-state stream
    /// delivers the new session there. Returning identity here too would give
    /// the app two places to read it from.
    func signIn(email: String, password: String) async throws {
        let client = try SupabaseService.shared.client()
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await client.auth.signIn(email: email, password: password)
        } catch {
            throw Self.mapSignInError(error)
        }
    }

    /// Translates Supabase's log-in errors into something a person can act on.
    ///
    /// Matches on `AuthError.errorCode` rather than on message text, so
    /// rewording on Supabase's side cannot silently break the mapping.
    static func mapSignInError(_ error: Error) -> SignInError {
        let message = error.localizedDescription

        guard let authError = error as? AuthError else {
            return .other(message)
        }

        switch authError.errorCode {
        case .invalidCredentials:
            return .invalidCredentials
        case .emailNotConfirmed:
            return .emailNotConfirmed
        default:
            return .other(message)
        }
    }

    /// Translates Supabase's sign-up errors into something a person can act on.
    ///
    /// Matches on `AuthError.errorCode` rather than on message text, with one
    /// unavoidable exception noted below.
    static func mapSignUpError(_ error: Error) -> SignUpError {
        let message = error.localizedDescription

        // From the availability pre-check, which speaks PostgREST rather than
        // GoTrue. PostgrestError is not a LocalizedError, so its
        // localizedDescription is Foundation boilerplate; use the server's own.
        if let postgrestError = error as? PostgrestError {
            return .other(postgrestError.message)
        }

        guard let authError = error as? AuthError else {
            return .other(message)
        }

        // A duplicate username fails inside the profiles trigger, and Supabase
        // has no dedicated error code for it. What comes back depends on
        // whether the caller sends an API-version header:
        //
        //   with the header (what the SDK sends, so what we see in the app):
        //     message "Database error saving new user", code unexpected_failure
        //
        //   without it (e.g. plain curl), the raw Postgres error:
        //     {"code": "23505",
        //      "message": "duplicate key value violates unique constraint
        //                  \"profiles_username_key\""}
        //
        // The raw form names the constraint and is unambiguous. The sanitised
        // form is not: GoTrue uses that one sentence for *any* failure inside
        // the sign-up transaction — a rejected CHECK, a broken trigger, an
        // outage — and mapping it to "username taken" turned every one of
        // those into a report of a user mistake. With the format validated and
        // availability checked before the request, the realistic causes left
        // are losing a race for the username and a genuine server-side
        // failure; `.accountCreationFailed` is worded to cover both.
        if authError.errorCode == Self.postgresUniqueViolation
            || message.contains("profiles_username_key") {
            return .usernameTaken
        }

        let lowercased = message.lowercased()
        if lowercased.contains("database error saving new user") {
            return .accountCreationFailed
        }

        switch authError.errorCode {
        case .emailExists, .userAlreadyExists:
            return .emailAlreadyRegistered

        case .weakPassword:
            // The server explains what is wrong with the password (length,
            // character classes); pass that through rather than inventing
            // wording that could contradict the project's actual policy.
            return .weakPassword(message)

        case .validationFailed:
            // Only email format is validated today, but the code is generic,
            // so confirm before claiming it is the email.
            return lowercased.contains("email") ? .invalidEmail : .other(message)

        default:
            return .other(message)
        }
    }

    /// Postgres SQLSTATE for `unique_violation`. Not a Supabase auth code — it
    /// arrives when a database constraint rejects the trigger's insert.
    private static let postgresUniqueViolation = ErrorCode("23505")
}
