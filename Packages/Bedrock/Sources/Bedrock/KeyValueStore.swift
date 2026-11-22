import Foundation

/// A storage place for small strings.
///
/// Formulated as a protocol so tests need not touch the real keychain. It blocks
/// on a computer as soon as it expects an authorization: a test run then simply
/// stalls, without an error message. That is exactly what happened when this
/// store was built.
public protocol KeyValueStore: Sendable {
    func set(_ value: String, for key: String) throws
    func value(for key: String) throws -> String
    func remove(_ key: String) throws
}

extension SecureStore: KeyValueStore {}

/// Volatile in-memory store, for tests only.
public final class InMemoryStore: KeyValueStore, @unchecked Sendable {

    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func set(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public func value(for key: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[key] else { throw SecureStore.Failure.notFound }
        return value
    }

    public func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}
