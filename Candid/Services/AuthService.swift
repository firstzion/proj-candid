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
        // Match any of the three. The sanitized sentence is the one that
        // actually reaches the app today; the SQLSTATE and the constraint name
        // are standard Postgres and our own migration respectively, and cover
        // the versionless shape. username is the only unique constraint this
        // insert can violate.
        let lowercased = message.lowercased()
        if authError.errorCode == Self.postgresUniqueViolation
            || message.contains("profiles_username_key")
            || lowercased.contains("database error saving new user") {
            return .usernameTaken
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
