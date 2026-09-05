import Foundation
import Testing
import Supabase
@testable import Candid

/// `ProfileService.changeUsername(to:)` (SOL-41): the request, and the two
/// refusals the database can answer with — a taken (or reserved) name, and a
/// change made too soon, which carries the date the next one is allowed.
///
/// `.serialized`: `StubURLProtocol`'s state is process-global.
@Suite(.serialized)
struct ProfileServiceUsernameChangeTests {
    private static let me = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static func makeService() -> ProfileService {
        ProfileService(client: TestSupabaseClient.make(), currentUserID: { Self.me })
    }

    @Test("changeUsername updates the caller's own row with the normalised name")
    func changeUpdatesOwnRow() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 204, body: Data()) }

        try await Self.makeService().changeUsername(to: "  Alice_Renamed ")

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/rest/v1/profiles")
        #expect(request.queryParameters["id"] == "eq.\(Self.me.uuidString)")
        struct Body: Decodable { let username: String }
        let body = try JSONDecoder().decode(Body.self, from: try #require(request.drainedBody))
        #expect(body.username == "alice_renamed")
    }

    @Test("a name the rules refuse is refused here, without a request")
    func invalidNameSkipsRequest() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(statusCode: 500, body: Data()) }

        await #expect(throws: ProfileError.self) {
            try await Self.makeService().changeUsername(to: "Alice Smith")
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test("isUsernameAvailable asks username_available with the normalised name")
    func availability() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.setHandler { _ in .init(body: Data("false".utf8)) }

        let available = try await Self.makeService().isUsernameAvailable(" Alice ")
        #expect(available == false)
        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.url?.path == "/rest/v1/rpc/username_available")
        struct Params: Decodable { let candidate: String }
        let params = try JSONDecoder().decode(Params.self, from: try #require(request.drainedBody))
        #expect(params.candidate == "alice")
    }

    @Test("a unique violation, held or reserved, is a taken name")
    func takenOrReserved() {
        for message in [
            #"duplicate key value violates unique constraint "profiles_username_key""#,
            "that username was recently released and is reserved",
        ] {
            let mapped = ProfileService.mapUsernameChangeError(PostgrestError(code: "23505", message: message))
            guard case .usernameTaken = mapped else {
                Issue.record("expected .usernameTaken for \(message), got \(mapped)")
                return
            }
        }
    }

    @Test("the rate limit carries the date the next change is allowed")
    func tooSoonCarriesTheDate() throws {
        let mapped = ProfileService.mapUsernameChangeError(
            PostgrestError(code: "23514", message: "username can be changed again on 2026-10-04")
        )
        guard case .usernameChangeTooSoon(let date) = mapped else {
            Issue.record("expected .usernameChangeTooSoon, got \(mapped)")
            return
        }
        let parsed = try #require(date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day], from: parsed)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 4)
        #expect(mapped.errorDescription?.contains("again on") == true)
    }

    @Test("a date-less rate-limit message still reads as too soon")
    func tooSoonWithoutDate() {
        let mapped = ProfileService.mapUsernameChangeError(
            PostgrestError(code: "23514", message: "username can be changed again on (unknown)")
        )
        guard case .usernameChangeTooSoon(nil) = mapped else {
            Issue.record("expected .usernameChangeTooSoon(nil), got \(mapped)")
            return
        }
        #expect(mapped.errorDescription?.contains("30 days") == true)
    }
}
