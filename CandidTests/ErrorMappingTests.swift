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

    /// GoTrue returns this one sanitised sentence for *any* failure inside the
    /// sign-up transaction — a lost race for a username, but equally a rejected
    /// CHECK, a broken trigger or an outage. It used to map to "username
    /// taken", which turned every server-side failure into a report of a user
    /// mistake. A regression here previously reached the user as raw server
    /// text, so the shape is pinned either way.
    @Test("the sanitised database error is a failed creation, not a taken username")
    func sanitizedDatabaseError() {
        let mapped = AuthService.mapSignUpError(
            apiError(message: "Database error saving new user", code: .unexpectedFailure)
        )
        guard case .accountCreationFailed = mapped else {
            Issue.record("expected .accountCreationFailed, got \(mapped)")
            return
        }
        // The wording must leave both causes open.
        #expect(mapped.errorDescription?.contains("may have") == true)
    }

    /// The versionless shape names the constraint, so it is unambiguous.
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
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("offline"))
    }

    /// The availability pre-check speaks PostgREST, not GoTrue. PostgrestError
    /// is not a LocalizedError, so its localizedDescription is boilerplate.
    @Test("a PostgREST error from the availability check carries the server's message")
    func postgrestErrorSurvives() {
        let mapped = AuthService.mapSignUpError(
            PostgrestError(code: "42883", message: "function public.username_available(text) does not exist")
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("Something went wrong"))
        #expect(message.contains("function public.username_available(text) does not exist"))
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
    @Test("an unrecognised PostgREST error carries the server's words, not boilerplate")
    func serverMessageSurvives() {
        let mapped = ProfileService.mapProfileError(
            PostgrestError(code: "42501", message: "permission denied for table profiles")
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("Something went wrong"))
        #expect(message.contains("permission denied for table profiles"))
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

    @Test("a missing session is reported as not signed in")
    func sessionMissing() {
        let mapped = ProfileService.mapSessionError(AuthError.sessionMissing)
        guard case .notSignedIn = mapped else {
            Issue.record("expected .notSignedIn, got \(mapped)")
            return
        }
    }

    /// Regression test. Every failure to read the session — a refresh that
    /// could not reach the server included — used to be reported as "You're
    /// not signed in", while the tabs on screen said otherwise.
    @Test("a session that merely failed to refresh is not called not signed in")
    func refreshFailureIsNotSignedOut() {
        let mapped = ProfileService.mapSessionError(URLError(.notConnectedToInternet))
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
    @Test("an unrecognised storage error carries the server's words, not boilerplate")
    func serverMessageSurvives() {
        let mapped = StorageService.mapStorageError(
            StorageError(statusCode: "413", message: "The object exceeded the maximum allowed size", error: nil)
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("Something went wrong"))
        #expect(message.contains("The object exceeded the maximum allowed size"))
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

    @Test("an unrecognised PostgREST error carries the server's words, not boilerplate")
    func serverMessageSurvives() {
        let mapped = PostService.mapPostError(
            PostgrestError(code: "23503", message: "insert or update on table \"posts\" violates foreign key constraint")
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("Something went wrong"))
        #expect(message.contains("foreign key constraint"))
    }

    @Test("a missing session is reported as not signed in")
    func sessionMissing() {
        let mapped = PostService.mapSessionError(AuthError.sessionMissing)
        guard case .notSignedIn = mapped else {
            Issue.record("expected .notSignedIn, got \(mapped)")
            return
        }
    }

    @Test("a session that merely failed to refresh is not called not signed in")
    func refreshFailureIsNotSignedOut() {
        let mapped = PostService.mapSessionError(URLError(.notConnectedToInternet))
        guard case .other = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
    }

    @Test("a caption at the limit is accepted; one over it is refused before upload")
    func captionLength() throws {
        try PostService.validateCaption(nil)
        try PostService.validateCaption(String(repeating: "a", count: PostService.maxCaptionLength))
        #expect(throws: PostError.self) {
            try PostService.validateCaption(String(repeating: "a", count: PostService.maxCaptionLength + 1))
        }
    }

    /// Postgres' char_length counts code points, so the client must too: a
    /// flag emoji is one Character to Swift but two to the CHECK constraint.
    @Test("caption length is measured the way the database measures it")
    func captionLengthCountsScalars() {
        let flag = "🇬🇧"
        let atLimit = String(repeating: flag, count: PostService.maxCaptionLength / 2)
        #expect(throws: Never.self) { try PostService.validateCaption(atLimit) }
        #expect(throws: PostError.self) { try PostService.validateCaption(atLimit + "a") }
    }
}

@Suite("Feed error mapping")
struct FeedErrorMappingTests {
    /// Same boilerplate trap as the other PostgrestError mappers.
    @Test("PostgREST errors carry the server's words, not boilerplate")
    func serverMessageSurvives() {
        let mapped = FeedService.mapFeedError(
            PostgrestError(code: "42501", message: "permission denied for table posts")
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("Something went wrong"))
        #expect(message.contains("permission denied for table posts"))
    }

    /// Proof that the network shortcut reaches the screen through a real
    /// mapper, not only through `fallbackMessage` in isolation: being offline
    /// is the one failure here the person can act on.
    @Test("a dropped connection is named as being offline")
    func nonPostgrestError() {
        let mapped = FeedService.mapFeedError(URLError(.notConnectedToInternet))
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("offline"))
        #expect(!message.contains("Something went wrong"))
    }
}

@Suite("Follow error mapping")
struct FollowErrorMappingTests {
    /// follows_no_self_follow and blocks_no_self_block are the only CHECK
    /// constraints on the graph tables, and both say the same thing.
    @Test("a self-follow or self-block rejected by a CHECK constraint is named as such")
    func targetingSelf() {
        for message in [
            #"new row for relation "follows" violates check constraint "follows_no_self_follow""#,
            #"new row for relation "blocks" violates check constraint "blocks_no_self_block""#,
        ] {
            let mapped = FollowService.mapFollowError(PostgrestError(code: "23514", message: message))
            guard case .cannotTargetSelf = mapped else {
                Issue.record("expected .cannotTargetSelf for \(message), got \(mapped)")
                return
            }
        }
    }

    @Test("following an account that no longer exists is reported as missing")
    func deletedAccount() {
        let mapped = FollowService.mapFollowError(
            PostgrestError(code: "23503", message: #"insert or update on table "follows" violates foreign key constraint "follows_followee_id_fkey""#)
        )
        guard case .accountMissing = mapped else {
            Issue.record("expected .accountMissing, got \(mapped)")
            return
        }
    }

    /// Once blocking lands, the insert policy refuses an edge across a block
    /// and the refusal arrives exactly like this. The wording must stay
    /// generic: a block is silent to the person on the other side of it.
    @Test("an RLS refusal is reported without saying why")
    func rlsRefusal() {
        let mapped = FollowService.mapFollowError(
            PostgrestError(code: "42501", message: #"new row violates row-level security policy for table "follows""#)
        )
        guard case .notPermitted = mapped else {
            Issue.record("expected .notPermitted, got \(mapped)")
            return
        }
        let wording = mapped.errorDescription?.lowercased() ?? ""
        #expect(!wording.contains("block"))
        #expect(!wording.contains("policy"))
    }

    /// Same boilerplate trap as the other PostgrestError mappers.
    @Test("an unrecognised PostgREST error carries the server's words, not boilerplate")
    func serverMessageSurvives() {
        let mapped = FollowService.mapFollowError(
            PostgrestError(code: "42P01", message: #"relation "public.follows" does not exist"#)
        )
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("Something went wrong"))
        #expect(message.contains(#"relation "public.follows" does not exist"#))
    }

    @Test("a timeout is named as one rather than folded into the generic sentence")
    func nonPostgrestError() {
        let mapped = FollowService.mapFollowError(URLError(.timedOut))
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(message.contains("took too long"))
        #expect(!message.contains("Something went wrong"))
    }

    /// The composite primary key refusing a second identical edge. `follow`
    /// treats this as success rather than an error — the state asked for
    /// already holds — so recognising it precisely matters.
    @Test("a duplicate edge is recognised by its unique_violation code alone")
    func duplicateEdge() {
        #expect(FollowService.isDuplicateEdge(
            PostgrestError(code: "23505", message: #"duplicate key value violates unique constraint "follows_pkey""#)
        ))
        #expect(!FollowService.isDuplicateEdge(PostgrestError(code: "23514", message: "check_violation")))
        #expect(!FollowService.isDuplicateEdge(URLError(.timedOut)))
    }

    @Test("a missing session is reported as not signed in")
    func sessionMissing() {
        let mapped = FollowService.mapSessionError(AuthError.sessionMissing)
        guard case .notSignedIn = mapped else {
            Issue.record("expected .notSignedIn, got \(mapped)")
            return
        }
    }

    @Test("a session that merely failed to refresh is not called not signed in")
    func refreshFailureIsNotSignedOut() {
        let mapped = FollowService.mapSessionError(URLError(.notConnectedToInternet))
        guard case .other = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
    }
}

/// The wording an unrecognised failure lands on, in both build configurations.
///
/// The mapper suites above exercise only the Debug wording, because they call
/// the mappers and the mappers take the default. This is where the Release
/// wording is pinned — which is the whole reason `fallbackMessage` takes
/// `includeDetail` as a parameter instead of reading `#if DEBUG` in its body:
/// CI builds Debug, so a compile-time branch would have left the wording real
/// users see untested in every run.
@Suite("Fallback error wording")
struct FallbackMessageTests {
    private let serverDetail = "permission denied for table posts"

    private var postgrestFailure: PostgrestError {
        PostgrestError(code: "42501", message: serverDetail)
    }

    @Test("a Debug build carries the server's words, so a failure is diagnosable on sight")
    func debugCarriesDetail() {
        let message = fallbackMessage(for: postgrestFailure, context: "test", includeDetail: true)
        #expect(message.contains("Something went wrong"))
        #expect(message.contains(serverDetail))
    }

    /// The card's point: no PostgREST, Storage or GoTrue wording reaches a
    /// person. Asserted as an exact string rather than a `!contains`, so a
    /// future edit that starts appending something has to come through here.
    @Test("a Release build shows none of the server's wording")
    func releaseHidesDetail() {
        let message = fallbackMessage(for: postgrestFailure, context: "test", includeDetail: false)
        #expect(message == "Something went wrong. Try again.")
    }

    /// Being offline is the one failure the person can fix, so it says so —
    /// and says the same thing in both builds, since there is no server
    /// detail worth appending to it.
    @Test("being offline says so, in either build")
    func offline() {
        let expected = "You're offline. Check your connection and try again."
        #expect(fallbackMessage(for: URLError(.notConnectedToInternet), context: "test", includeDetail: true) == expected)
        #expect(fallbackMessage(for: URLError(.notConnectedToInternet), context: "test", includeDetail: false) == expected)
    }

    @Test("a connection lost mid-request reads the same as being offline")
    func connectionLost() {
        let message = fallbackMessage(for: URLError(.networkConnectionLost), context: "test", includeDetail: false)
        #expect(message.contains("offline"))
    }

    @Test("a timeout gets its own sentence, in either build")
    func timedOut() {
        let expected = "That took too long. Try again."
        #expect(fallbackMessage(for: URLError(.timedOut), context: "test", includeDetail: true) == expected)
        #expect(fallbackMessage(for: URLError(.timedOut), context: "test", includeDetail: false) == expected)
    }

    /// Any other `URLError` is not something the person can act on, so it
    /// takes the generic path rather than inventing a network explanation for
    /// what may not be one.
    @Test("an unrelated URLError takes the generic path")
    func otherURLError() {
        let message = fallbackMessage(for: URLError(.badServerResponse), context: "test", includeDetail: false)
        #expect(message == "Something went wrong. Try again.")
    }
}
