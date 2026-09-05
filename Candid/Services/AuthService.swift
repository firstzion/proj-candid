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
    case inviteMissing
    case inviteNotFound
    case inviteRedeemed
    case inviteExpired
    case accountCreationFailed
    case other(String)

    var errorDescription: String? {
        switch self {
        case .inviteMissing:
            return "Enter the invite code you were sent."
        case .inviteNotFound:
            return "That code doesn't exist. Check it against the message you were sent."
        case .inviteRedeemed:
            return "That code has already been used."
        case .inviteExpired:
            return "That code has expired. Ask for a new one."
        case .emailAlreadyRegistered:
            // Deliberate email enumeration, unlike the log-in path below.
            // Decision (SOL-53): accepted for now — most consumer apps make
            // this trade for the better sign-up UX, and severity is low for a
            // friends-only app. Once email confirmation is enabled, GoTrue
            // itself returns a fake success for a duplicate address instead
            // of an error, so this case fires only while confirmations are
            // off; revisit removing it entirely at that point.
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
            // `mapSignUpError`. With the format validated, availability
            // checked and the invite code's status asked first, this is a
            // lost race for the username or the code — the trigger refuses a
            // code used a moment ago — or a genuine server-side failure; the
            // wording leaves them all open rather than asserting one.
            return "The account couldn't be created. That username or invite code may have just been taken — try again in a moment."
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
    /// False when the project still requires email confirmation, in which case
    /// the account exists but is not usable until the link is clicked.
    let hasActiveSession: Bool
}

struct AuthService {
    let client: SupabaseClient

    /// Creates the account. Sign-up is invite-only (SOL-61): `inviteCode` is
    /// checked with `invite_status` first so each of the three ways a code can
    /// be bad gets its own sentence, then travels in the sign-up metadata,
    /// where the database trigger is the enforcement — it refuses a missing,
    /// unknown, used or expired code and rolls the whole sign-up back, so a
    /// bad code never leaves an orphaned account. The trigger also redeems
    /// the code and makes inviter and invitee friends, in the same
    /// transaction (SOL-62).
    func signUp(email: String, password: String, username: String, inviteCode: String) async throws -> SignUpResult {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = UsernameRules.normalized(username)
        let inviteCode = InviteService.normalized(inviteCode)

        // Say precisely what is wrong before any request. The database enforces
        // the same rules, but a CHECK failure inside the sign-up trigger comes
        // back as GoTrue's sanitised "Database error saving new user".
        if let problem = UsernameRules.validationProblem(username) {
            throw SignUpError.invalidUsername(problem)
        }
        guard !inviteCode.isEmpty else {
            throw SignUpError.inviteMissing
        }

        // The gate's wording. Advisory like the availability check below: a
        // code that is spent between this answer and the sign-up is refused
        // by the trigger and reported as `.accountCreationFailed`.
        switch try await inviteStatus(inviteCode) {
        case .valid:
            break
        case .notFound:
            throw SignUpError.inviteNotFound
        case .redeemed:
            throw SignUpError.inviteRedeemed
        case .expired:
            throw SignUpError.inviteExpired
        }

        // Ask before creating the auth user, for the same reason: a duplicate
        // that fails inside the trigger is unrecognisable by the time it gets
        // here. Advisory only — see `isUsernameAvailable`.
        guard try await isUsernameAvailable(username) else {
            throw SignUpError.usernameTaken
        }

        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["username": .string(username), "invite_code": .string(inviteCode)]
            )
            return SignUpResult(hasActiveSession: response.session != nil)
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
    private func isUsernameAvailable(_ username: String) async throws -> Bool {
        do {
            return try await client
                .rpc("username_available", params: ["candidate": username])
                .execute()
                .value
        } catch {
            throw Self.mapSignUpError(error)
        }
    }

    /// Asks `invite_status` about the code, through `InviteService`. The
    /// person asking has no session yet; the function is callable by `anon`
    /// and answers one enum value.
    private func inviteStatus(_ code: String) async throws -> InviteState {
        do {
            return try await InviteService(client: client).status(code: code)
        } catch {
            throw SignUpError.other(fallbackMessage(for: error, context: "AuthService.inviteStatus"))
        }
    }

    /// Signs in. Deliberately returns nothing: `SessionStore` is the single
    /// source of truth for who is signed in, and the SDK's auth-state stream
    /// delivers the new session there. Returning identity here too would give
    /// the app two places to read it from.
    func signIn(email: String, password: String) async throws {
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
        guard let authError = error as? AuthError else {
            return .other(fallbackMessage(for: error, context: "AuthService.mapSignInError"))
        }

        switch authError.errorCode {
        case .invalidCredentials:
            return .invalidCredentials
        case .emailNotConfirmed:
            return .emailNotConfirmed
        default:
            return .other(fallbackMessage(for: error, context: "AuthService.mapSignInError"))
        }
    }

    /// Translates Supabase's sign-up errors into something a person can act on.
    ///
    /// Matches on `AuthError.errorCode` rather than on message text, with one
    /// unavoidable exception noted below.
    static func mapSignUpError(_ error: Error) -> SignUpError {
        // The server's raw text, which the two matches below read and which
        // `.weakPassword` passes through deliberately. It is never what goes
        // on screen for an unrecognised failure — that is `fallbackMessage`.
        let message = error.localizedDescription

        // From the availability pre-check, which speaks PostgREST rather than
        // GoTrue.
        if error is PostgrestError {
            return .other(fallbackMessage(for: error, context: "AuthService.mapSignUpError"))
        }

        guard let authError = error as? AuthError else {
            return .other(fallbackMessage(for: error, context: "AuthService.mapSignUpError"))
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
            return lowercased.contains("email")
                ? .invalidEmail
                : .other(fallbackMessage(for: error, context: "AuthService.mapSignUpError"))

        default:
            return .other(fallbackMessage(for: error, context: "AuthService.mapSignUpError"))
        }
    }

    /// Postgres SQLSTATE for `unique_violation`. Not a Supabase auth code — it
    /// arrives when a database constraint rejects the trigger's insert.
    private static let postgresUniqueViolation = ErrorCode("23505")
}
