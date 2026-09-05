import Foundation
import Testing
import Supabase
@testable import Candid

/// `AuthService.signUp` against stubbed endpoints: the invite gate (SOL-61).
/// What is pinned is that a code which is not valid stops the flow before
/// any account is asked for, and that a valid one travels in the sign-up
/// metadata where the trigger reads it.
///
/// Each test builds its own `TestSupabaseClient`, which carries its own
/// `StubURLProtocol` host (SOL-75), so tests are isolated without needing
/// `.serialized`.
@Suite
struct AuthServiceSignUpTests {
    private static func signUp(_ service: AuthService, code: String) async throws -> SignUpResult {
        try await service.signUp(email: "new@example.com", password: "correct horse battery", username: "newcomer", inviteCode: code)
    }

    @Test("a code that is not valid stops the sign-up with its own sentence, before any request but the status check")
    func stopsAtABadCode() async throws {
        let stub = TestSupabaseClient.make()
        let service = AuthService(client: stub.client)

        let cases: [(state: String, expected: SignUpError)] = [
            ("not_found", .inviteNotFound),
            ("redeemed", .inviteRedeemed),
            ("expired", .inviteExpired),
        ]
        for (state, expected) in cases {
            stub.reset()
            stub.setHandler { request in
                request.url?.path == "/rest/v1/rpc/invite_status"
                    ? .init(body: Data("\"\(state)\"".utf8))
                    : .init(statusCode: 500, body: Data())
            }
            do {
                _ = try await Self.signUp(service, code: " candd-seed3 ")
                Issue.record("expected \(expected) for \(state)")
            } catch let error as SignUpError {
                #expect(error.errorDescription == expected.errorDescription, "state \(state)")
            }
            // Exactly one request, to the status function, with the normalised code.
            #expect(stub.requests.count == 1)
            let request = try #require(stub.requests.first)
            #expect(request.url?.path == "/rest/v1/rpc/invite_status")
            struct Params: Decodable { let p_code: String }
            let params = try JSONDecoder().decode(Params.self, from: try #require(request.drainedBody))
            #expect(params.p_code == "CANDD-SEED3")
        }
    }

    @Test("a blank code is refused without any request")
    func blankCode() async throws {
        let stub = TestSupabaseClient.make()
        stub.setHandler { _ in .init(statusCode: 500, body: Data()) }

        do {
            _ = try await Self.signUp(AuthService(client: stub.client), code: "   ")
            Issue.record("expected .inviteMissing")
        } catch let error as SignUpError {
            guard case .inviteMissing = error else {
                Issue.record("expected .inviteMissing, got \(error)")
                return
            }
        }
        #expect(stub.requests.isEmpty)
    }

    /// The trigger reads `invite_code` from the metadata; a sign-up that did
    /// not carry it would be refused for every code, valid or not.
    @Test("a valid code travels in the sign-up metadata, after the status and availability checks")
    func validCodeIsSent() async throws {
        let stub = TestSupabaseClient.make()
        stub.setHandler { request in
            switch request.url?.path {
            case "/rest/v1/rpc/invite_status":
                return .init(body: Data("\"valid\"".utf8))
            case "/rest/v1/rpc/username_available":
                return .init(body: Data("true".utf8))
            default:
                // The sign-up itself is answered with an error: what is under
                // test is the request, not GoTrue's response shape. 400 rather
                // than 500 on purpose — the Auth client wraps a
                // RetryRequestInterceptor that retries POST requests once on
                // any of its default retryable status codes, 500 included
                // (Sources/Helpers/HTTP/RetryRequestInterceptor.swift), so a
                // 500 here would silently record two /auth/v1/signup requests
                // instead of the one this test means to pin.
                return .init(statusCode: 400, body: Data(#"{"code":"unexpected_failure","msg":"stub"}"#.utf8))
            }
        }

        _ = try? await Self.signUp(AuthService(client: stub.client), code: "candd-seed2")

        let paths = stub.requests.compactMap { $0.url?.path }
        #expect(paths == ["/rest/v1/rpc/invite_status", "/rest/v1/rpc/username_available", "/auth/v1/signup"])

        let signUp = try #require(stub.requests.last)
        struct Body: Decodable {
            struct Metadata: Decodable {
                let username: String
                let invite_code: String
            }
            let email: String
            let data: Metadata
        }
        let body = try JSONDecoder().decode(Body.self, from: try #require(signUp.drainedBody))
        #expect(body.email == "new@example.com")
        #expect(body.data.username == "newcomer")
        #expect(body.data.invite_code == "CANDD-SEED2")
    }
}

/// `PendingInvite.code(from:)`: the invite deep link, and nothing else.
@Suite("Invite deep link")
struct PendingInviteTests {
    @Test("an invite link yields its normalised code")
    func inviteLink() {
        #expect(PendingInvite.code(from: URL(string: "candid://invite/candd-seed2")!) == "CANDD-SEED2")
        #expect(PendingInvite.code(from: URL(string: "CANDID://INVITE/ABCDE-FGHJK")!) == "ABCDE-FGHJK")
    }

    @Test("the auth callback and a link with no code yield nothing")
    func otherLinks() {
        #expect(PendingInvite.code(from: URL(string: "candid://auth-callback#access_token=x")!) == nil)
        #expect(PendingInvite.code(from: URL(string: "candid://invite")!) == nil)
        #expect(PendingInvite.code(from: URL(string: "candid://invite/")!) == nil)
        #expect(PendingInvite.code(from: URL(string: "https://example.com/invite/ABCDE-FGHJK")!) == nil)
    }

    /// SOL-76: signed in, `LogInView` isn't even mounted to consume a code,
    /// so a link tapped there is held only while signed out.
    @Test("a code is held only while signed out")
    func shouldHold() {
        #expect(PendingInvite.shouldHold(isSignedIn: false) == true)
        #expect(PendingInvite.shouldHold(isSignedIn: true) == false)
    }
}
