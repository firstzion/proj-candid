import Foundation
import Supabase

/// Errors surfaced to the sign-up screen.
///
/// Supabase returns these as opaque API errors, so they are recognised by
/// message rather than by a typed code.
enum SignUpError: LocalizedError {
    case emailAlreadyRegistered
    case usernameTaken
    case invalidEmail
    case weakPassword(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .emailAlreadyRegistered:
            return "An account with that email already exists."
        case .usernameTaken:
            return "That username is already taken. Try another one."
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

struct SignInResult {
    let userID: UUID
    let email: String?
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
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)

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

    func signIn(email: String, password: String) async throws -> SignInResult {
        let client = try SupabaseService.shared.client()
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let session = try await client.auth.signIn(email: email, password: password)
            return SignInResult(userID: session.user.id, email: session.user.email)
        } catch {
            throw Self.mapSignInError(error)
        }
    }

    /// The session the SDK is currently holding, if any.
    ///
    /// Reads straight from the SDK rather than caching: supabase-swift persists
    /// the session in the Keychain and refreshes it on its own
    /// (`defaultLocalStorage` is `KeychainLocalStorage`, `autoRefreshToken`
    /// defaults to true), so there is no custom persistence to build.
    func currentSessionEmail() -> String? {
        guard let client = try? SupabaseService.shared.client() else { return nil }
        return client.auth.currentSession?.user.email
    }

    static func mapSignInError(_ error: Error) -> SignInError {
        let haystack = error.localizedDescription.lowercased()

        if haystack.contains("invalid login credentials")
            || haystack.contains("invalid credentials") {
            return .invalidCredentials
        }

        if haystack.contains("email not confirmed") {
            return .emailNotConfirmed
        }

        return .other(error.localizedDescription)
    }

    /// Translates Supabase's API errors into something a person can act on.
    static func mapSignUpError(_ error: Error) -> SignUpError {
        let message = error.localizedDescription
        let haystack = message.lowercased()

        // The profiles trigger inserts the username, so a duplicate username
        // fails inside the trigger. Supabase reports that as a generic
        // "Database error saving new user". username is the only unique
        // constraint that insert can violate, so attribute it to the username.
        if haystack.contains("database error saving new user")
            || haystack.contains("profiles_username_key")
            || haystack.contains("duplicate key value") {
            return .usernameTaken
        }

        if haystack.contains("already registered")
            || haystack.contains("already been registered")
            || haystack.contains("user already exists") {
            return .emailAlreadyRegistered
        }

        if haystack.contains("password") {
            return .weakPassword(message)
        }

        if haystack.contains("email") && haystack.contains("invalid") {
            return .invalidEmail
        }

        return .other(message)
    }
}
