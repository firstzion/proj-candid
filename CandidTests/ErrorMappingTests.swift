import Foundation
import Testing
import Supabase
@testable import Candid

/// These functions translate opaque server errors into wording a person can act
/// on. They are pure, and they are the part of the app most likely to rot
/// silently when Supabase rewords something — which is exactly what happened
/// once already before these tests existed.
private func apiError(message: String, code: ErrorCode) -> AuthError {
    .api(
        message: message,
        errorCode: code,
        underlyingData: Data(),
        underlyingResponse: HTTPURLResponse(
            url: URL(string: "https://example.supabase.co")!,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        )!
    )
}

@Suite("Sign-up error mapping")
struct SignUpErrorMappingTests {
    @Test("user_already_exists is reported as a taken email")
    func userAlreadyExists() {
        let mapped = AuthService.mapSignUpError(
            apiError(message: "User already registered", code: .userAlreadyExists)
        )
        guard case .emailAlreadyRegistered = mapped else {
            Issue.record("expected .emailAlreadyRegistered, got \(mapped)")
            return
        }
    }

    @Test("email_exists is reported as a taken email")
    func emailExists() {
        let mapped = AuthService.mapSignUpError(
            apiError(message: "Email address already in use", code: .emailExists)
        )
        guard case .emailAlreadyRegistered = mapped else {
            Issue.record("expected .emailAlreadyRegistered, got \(mapped)")
            return
        }
    }

    @Test("weak_password passes the server's explanation through unchanged")
    func weakPassword() {
        let mapped = AuthService.mapSignUpError(
            AuthError.weakPassword(message: "Password should be at least 6 characters.", reasons: ["length"])
        )
        guard case .weakPassword(let detail) = mapped else {
            Issue.record("expected .weakPassword, got \(mapped)")
            return
        }
        // The server knows the project's actual policy; we must not reword it.
        #expect(detail.contains("at least 6 characters"))
    }

    /// A duplicate username fails inside the profiles trigger. Supabase has no
    /// error code for it, and the shape depends on whether the caller sent an
    /// API-version header. Both forms must map to the same message — a
    /// regression here previously reached the user as raw server text.
    @Test("duplicate username is recognised in its sanitized form")
    func duplicateUsernameSanitized() {
        let mapped = AuthService.mapSignUpError(
            apiError(message: "Database error saving new user", code: .unexpectedFailure)
        )
        guard case .usernameTaken = mapped else {
            Issue.record("expected .usernameTaken, got \(mapped)")
            return
        }
    }

    @Test("duplicate username is recognised in its raw Postgres form")
    func duplicateUsernameRaw() {
        let mapped = AuthService.mapSignUpError(
            apiError(
                message: #"duplicate key value violates unique constraint "profiles_username_key""#,
                code: ErrorCode("23505")
            )
        )
        guard case .usernameTaken = mapped else {
            Issue.record("expected .usernameTaken, got \(mapped)")
            return
        }
    }

    @Test("an unrecognised code falls through carrying the server's message")
    func unknownCode() {
        let mapped = AuthService.mapSignUpError(
            apiError(message: "Something novel went wrong", code: ErrorCode("brand_new_code"))
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("Something novel went wrong"))
    }

    @Test("a non-auth error falls through rather than being mislabelled")
    func nonAuthError() {
        let mapped = AuthService.mapSignUpError(URLError(.notConnectedToInternet))
        guard case .other = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
    }
}

@Suite("Log-in error mapping")
struct SignInErrorMappingTests {
    @Test("invalid_credentials keeps the ambiguity the API deliberately preserves")
    func invalidCredentials() {
        let mapped = AuthService.mapSignInError(
            apiError(message: "Invalid login credentials", code: .invalidCredentials)
        )
        guard case .invalidCredentials = mapped else {
            Issue.record("expected .invalidCredentials, got \(mapped)")
            return
        }
        // Unknown email and wrong password must be indistinguishable, so that
        // the screen cannot be used to discover which addresses are registered.
        #expect(mapped.errorDescription == "That email or password is incorrect.")
    }

    @Test("email_not_confirmed is called out separately")
    func emailNotConfirmed() {
        let mapped = AuthService.mapSignInError(
            apiError(message: "Email not confirmed", code: .emailNotConfirmed)
        )
        guard case .emailNotConfirmed = mapped else {
            Issue.record("expected .emailNotConfirmed, got \(mapped)")
            return
        }
    }

    @Test("anything else falls through carrying the server's message")
    func otherError() {
        let mapped = AuthService.mapSignInError(
            apiError(message: "Service unavailable", code: ErrorCode("over_request_rate_limit"))
        )
        guard case .other = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
    }
}

@Suite("Profile error mapping")
struct ProfileErrorMappingTests {
    @Test("PGRST116 means the profile row is missing or hidden by RLS")
    func noRows() {
        let mapped = ProfileService.mapProfileError(
            PostgrestError(code: "PGRST116", message: "JSON object requested, multiple (or no) rows returned")
        )
        guard case .profileMissing = mapped else {
            Issue.record("expected .profileMissing, got \(mapped)")
            return
        }
    }

    /// Regression test. PostgrestError is a plain Error, not a LocalizedError,
    /// so reading `localizedDescription` yields Foundation boilerplate and the
    /// server's actual complaint is lost. The mapper must read `message`.
    @Test("other PostgREST errors surface the server's message, not boilerplate")
    func serverMessageSurvives() {
        let mapped = ProfileService.mapProfileError(
            PostgrestError(code: "42501", message: "permission denied for table profiles")
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message == "permission denied for table profiles")
        #expect(!message.contains("The operation couldn"))
    }

    @Test("a non-PostgREST error falls through")
    func nonPostgrestError() {
        let mapped = ProfileService.mapProfileError(URLError(.timedOut))
        guard case .other = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
    }
}

@Suite("Storage error mapping")
struct StorageErrorMappingTests {
    @Test("a 403 is reported as a permission problem")
    func forbidden() {
        let mapped = StorageService.mapStorageError(
            StorageError(statusCode: "403", message: "Unauthorized", error: "Unauthorized")
        )
        guard case .notPermitted = mapped else {
            Issue.record("expected .notPermitted, got \(mapped)")
            return
        }
    }

    @Test("an RLS rejection is reported as a permission problem whatever the status")
    func rowLevelSecurity() {
        let mapped = StorageService.mapStorageError(
            StorageError(statusCode: "400", message: "new row violates row-level security policy", error: nil)
        )
        guard case .notPermitted = mapped else {
            Issue.record("expected .notPermitted, got \(mapped)")
            return
        }
    }

    /// Same boilerplate trap as PostgrestError: StorageError is a plain Error.
    @Test("other storage errors surface the server's message, not boilerplate")
    func serverMessageSurvives() {
        let mapped = StorageService.mapStorageError(
            StorageError(statusCode: "413", message: "The object exceeded the maximum allowed size", error: nil)
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message == "The object exceeded the maximum allowed size")
    }
}

@Suite("Post error mapping and caption handling")
struct PostServiceTests {
    @Test("a blank caption becomes null rather than an empty string")
    func blankCaptionIsNil() {
        #expect(PostService.normalizedCaption("") == nil)
        #expect(PostService.normalizedCaption("   ") == nil)
        #expect(PostService.normalizedCaption("\n\t ") == nil)
    }

    @Test("a real caption is trimmed but kept")
    func realCaptionIsTrimmed() {
        #expect(PostService.normalizedCaption("  hello  ") == "hello")
        #expect(PostService.normalizedCaption("hello") == "hello")
    }

    @Test("a caption of only interior whitespace is preserved verbatim inside")
    func interiorWhitespaceSurvives() {
        #expect(PostService.normalizedCaption(" a  b ") == "a  b")
    }

    @Test("an RLS rejection on insert is reported as a permission problem")
    func rlsRejection() {
        let mapped = PostService.mapPostError(
            PostgrestError(code: "42501", message: "new row violates row-level security policy for table \"posts\"")
        )
        guard case .notPermitted = mapped else {
            Issue.record("expected .notPermitted, got \(mapped)")
            return
        }
    }

    @Test("other PostgREST errors surface the server's message, not boilerplate")
    func serverMessageSurvives() {
        let mapped = PostService.mapPostError(
            PostgrestError(code: "23503", message: "insert or update on table \"posts\" violates foreign key constraint")
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("foreign key constraint"))
    }
}
