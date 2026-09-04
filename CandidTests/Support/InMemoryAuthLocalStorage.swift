import Foundation
import Supabase

/// A throwaway `AuthLocalStorage` for building a test `SupabaseClient`.
///
/// `SupabaseClientOptions.AuthOptions.storage` has no default — the SDK's own
/// default is Keychain-backed, which a unit test must not touch. Nothing
/// under test here calls into `auth`, so this only exists to satisfy the
/// initializer.
final class InMemoryAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}
