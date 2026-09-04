import Foundation
import Testing
@testable import Candid

/// `UsernameRules` mirrors the schema's CHECK constraint. If the two drift, a
/// username the form accepts fails inside the sign-up trigger and reaches the
/// person as the sanitised "Database error saving new user" — so the mirror is
/// worth pinning.
@Suite("Username rules")
struct UsernameRulesTests {
    @Test("normalisation lowercases and trims, as the trigger does")
    func normalisation() {
        #expect(UsernameRules.normalized("  Alice_01 \n") == "alice_01")
    }

    @Test("valid usernames pass, including both length bounds")
    func validNames() {
        #expect(UsernameRules.validationProblem("abc") == nil)
        #expect(UsernameRules.validationProblem("alice_01") == nil)
        #expect(UsernameRules.validationProblem(String(repeating: "a", count: UsernameRules.maxLength)) == nil)
    }

    @Test("too short and too long are each reported as such")
    func length() {
        #expect(UsernameRules.validationProblem("ab")?.contains("at least 3") == true)
        #expect(UsernameRules.validationProblem(String(repeating: "a", count: UsernameRules.maxLength + 1))?.contains("at most 30") == true)
    }

    @Test("anything outside a-z, 0-9 and underscore is rejected")
    func characters() {
        for bad in ["Alice", "alice smith", "alice-smith", "élodie", "alice.", "ali\u{200B}ce"] {
            #expect(UsernameRules.validationProblem(bad)?.contains("lowercase letters") == true, "\(bad) should have been rejected")
        }
    }

    @Test("characters are checked before length, so the message names the real problem")
    func charactersBeforeLength() {
        #expect(UsernameRules.validationProblem("É")?.contains("lowercase letters") == true)
    }
}
