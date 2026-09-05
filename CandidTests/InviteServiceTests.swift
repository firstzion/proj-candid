import Foundation
import Testing
import Supabase
@testable import Candid

/// `InviteService` against canned PostgREST responses, pinning the request
/// each method builds. Nothing here decides who may see or mint what — the
/// server does — so what matters is that each call asks the right thing.
///
/// `.serialized`: `StubURLProtocol`'s state is process-global.
@Suite(.serialized)
struct InviteServiceTests {
    private static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let bob = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private static func makeService() -> InviteService {
        InviteService(client: TestSupabaseClient.make(), currentUserID: { Self.me })
    }

    /// One row as PostgREST returns it, with the redeemer embed present,
    /// null, or absent (the RPC's shape).
    private static func row(code: String, redeemer: String?) -> String {
        #"{"code":"\#(code)","inviter_id":"\#(me.uuidString.lowercased())","redeemed_by":\#(redeemer == nil ? "null" : "\"\(bob.uuidString.lowercased())\""),"redeemed_at":\#(redeemer == nil ? "null" : "\"2026-09-01T10:00:00.000000+00:00\""),"created_at":"2026-08-30T10:00:00.000000+00:00","expires_at":"2026-09-29T10:00:00.000000+00:00","redeemer":\#(redeemer.map { "{\"username\":\"\($0)\"}" } ?? "null")}"#
    }

    @Test("status normalises the code and asks invite_status, which anyone may")
    func statusAsksTheFunction() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(body: Data("\"redeemed\"".utf8)) }

        let state = try await Self.makeService().status(code: " candd-seed3 ")
        #expect(state == .redeemed)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/rpc/invite_status")
        struct Params: Decodable { let p_code: String }
        let params = try JSONDecoder().decode(Params.self, from: try #require(request.drainedBody))
        #expect(params.p_code == "CANDD-SEED3")
    }

    @Test("create calls create_invite and decodes the minted row")
    func createMints() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in
            .init(body: Data(#"{"code":"ABCDE-FGHJK","inviter_id":"\#(Self.me.uuidString.lowercased())","redeemed_by":null,"redeemed_at":null,"created_at":"2026-09-04T10:00:00.000000+00:00","expires_at":"2026-10-04T10:00:00.000000+00:00"}"#.utf8))
        }

        let invite = try await Self.makeService().create()
        #expect(invite.code == "ABCDE-FGHJK")
        #expect(invite.state() == .unredeemed)
        #expect(invite.deepLink.absoluteString == "candid://invite/ABCDE-FGHJK")

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/v1/rpc/create_invite")
    }

    @Test("mine reads the caller's invites with the redeemer's username, newest first")
    func mineReadsOwnRows() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in
            .init(body: Data("[\(Self.row(code: "CANDD-SEED3", redeemer: "bob")),\(Self.row(code: "CANDD-SEED2", redeemer: nil))]".utf8))
        }

        let invites = try await Self.makeService().mine()
        #expect(invites.map(\.code) == ["CANDD-SEED3", "CANDD-SEED2"])
        #expect(invites[0].state() == .redeemed)
        #expect(invites[0].redeemer?.username == "bob")
        #expect(invites[1].redeemer == nil)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.url?.path == "/rest/v1/invites")
        let query = request.queryParameters
        #expect(query["select"] == "*,redeemer:profiles!invites_redeemed_by_fkey(username)")
        #expect(query["order"]?.hasPrefix("created_at.desc") == true)
    }

    @Test("revoke deletes by code; the policy decides whose and which")
    func revokeDeletesByCode() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 204, body: Data()) }

        try await Self.makeService().revoke(code: "candd-seed2")

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/rest/v1/invites")
        #expect(request.queryParameters["code"] == "eq.CANDD-SEED2")
    }

    @Test("quota reads the caller's own invite_quota")
    func quotaReadsOwnProfile() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(body: Data(#"{"invite_quota":5}"#.utf8)) }

        let quota = try await Self.makeService().quota()
        #expect(quota == 5)

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.url?.path == "/rest/v1/profiles")
        let query = request.queryParameters
        #expect(query["id"] == "eq.\(Self.me.uuidString)")
        #expect(query["select"] == "invite_quota")
    }

    @Test("the quota refusal is recognised by its code and message")
    func quotaRefusal() {
        let mapped = InviteService.mapError(PostgrestError(code: "23514", message: "invite quota reached"))
        guard case .quotaReached = mapped else {
            Issue.record("expected .quotaReached, got \(mapped)")
            return
        }
        let other = InviteService.mapError(PostgrestError(code: "23514", message: "some other check"))
        guard case .other = other else {
            Issue.record("expected .other, got \(other)")
            return
        }
    }
}

/// `Invite`'s own logic: which state a row is in, and what the share sheet
/// sends. The message has to work on a phone without the app, so the code
/// itself must be in it, not only the link.
@Suite("Invite model")
struct InviteModelTests {
    private static func invite(redeemedAt: Date? = nil, expiresAt: Date? = nil) -> Invite {
        Invite(
            code: "ABCDE-FGHJK",
            inviterID: UUID(),
            redeemedBy: redeemedAt == nil ? nil : UUID(),
            redeemedAt: redeemedAt,
            createdAt: .now,
            expiresAt: expiresAt,
            redeemer: nil
        )
    }

    @Test("the share message carries the code in plain text and the deep link")
    func shareMessage() {
        let message = Self.invite().shareMessage
        #expect(message.contains("ABCDE-FGHJK"))
        #expect(message.contains("candid://invite/ABCDE-FGHJK"))
    }

    @Test("redeemed beats expired, expired beats open, and no expiry never expires")
    func state() {
        let past = Date.now.addingTimeInterval(-3600)
        let future = Date.now.addingTimeInterval(3600)
        #expect(Self.invite(expiresAt: future).state() == .unredeemed)
        #expect(Self.invite(expiresAt: nil).state() == .unredeemed)
        #expect(Self.invite(expiresAt: past).state() == .expired)
        #expect(Self.invite(redeemedAt: past, expiresAt: past).state() == .redeemed)
    }
}
