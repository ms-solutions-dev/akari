import Foundation
import Security

/// Storage for credentials in the device's keychain.
///
/// Deliberately not in the ordinary settings: there, password and access token
/// would sit in plain text in a file every backup takes along. The keychain
/// encrypts them.
///
/// **What used to be stated here in addition was wrong:** "...and binds them to
/// the device." It does **not**, at least not with the access class set further
/// down. `kSecAttrAccessibleAfterFirstUnlock` without `ThisDeviceOnly` travels
/// into the encrypted backup and can be restored on a **different** device,
/// including server access, provider password and the PIN hash of the parental
/// controls.
///
/// The sentence is true compared with the ordinary settings (where everything is
/// in plain text) and was not true as a statement about the device.
///
/// **The class stays anyway, with a reason.** As long as device handover is not
/// wired up, restoring from a backup is the **only** way onto a new phone;
/// `ThisDeviceOnly` would take it away and put nothing in its place.
///
/// **Update:** the handover exists now. The keys that *identify* a device have
/// been switched (``init(service:accessGroup:onlyThisDevice:)``); accesses and
/// passwords stay with this class, because the handover brings them only to the
/// television and not to a new phone.
///
/// **What really mattered here has long been right:** `kSecAttrSynchronizable`
/// is set nowhere. There is no running synchronization via iCloud; the keychain
/// lives on this device and in its backup, nowhere else.
///
/// Also needed by the channel lists: accesses of the Xtream kind consist of user
/// name and password.
public struct SecureStore: Sendable {

    public enum Failure: Error, Equatable {
        case notFound
        /// The keychain refused. The number is the system's error code.
        case denied(OSStatus)
        case malformed
    }

    private let service: String

    /// Set only for entries that app and extension **share**: they then live in the
    /// keychain group of the app group instead of the target's own area. A `nil`
    /// changes nothing about the previous behavior.
    private let accessGroup: String?

    /// Entries **bound to this device** that do not travel to another device via a
    /// backup (`...ThisDeviceOnly`).
    ///
    /// Meant for keys that *identify* a device, such as the pairing credentials of
    /// the remote. If they traveled along, a device restored from a backup would pose
    /// as the old one until somebody pairs again. Accesses and passwords stay with
    /// the old class: for them the backup is an intended way onto a new device.
    ///
    /// Entries still stored with the old class are moved by ``value(for:)`` on first
    /// read, without the caller knowing.
    private let onlyThisDevice: Bool

    public init(
        service: String = ProgramID.bundle, accessGroup: String? = nil,
        onlyThisDevice: Bool = false
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.onlyThisDevice = onlyThisDevice
    }

    /// Readable after the first unlock, so the app can reach the access token even
    /// when launched in the background; with ``onlyThisDevice`` additionally bound
    /// to the device.
    var accessClass: CFString {
        onlyThisDevice
            ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlock
    }

    /// The shared parts of every query.
    private func query(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func set(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else { throw Failure.malformed }

        // Delete first, then write anew. Updating in place would be a second path with
        // its own failure cases, for no gain.
        try? remove(key)

        var query = query(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessClass

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.denied(status) }
    }

    public func value(for key: String) throws -> String {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            else { throw Failure.malformed }
            if onlyThisDevice { bind(key) }
            return string
        case errSecItemNotFound:
            throw Failure.notFound
        default:
            throw Failure.denied(status)
        }
    }

    /// Moves an entry to the device-bound class. If it is already there, nothing
    /// changes; if that fails, it stays readable as before and the next read tries
    /// again.
    private func bind(_ key: String) {
        _ = SecItemUpdate(
            query(for: key) as CFDictionary,
            [kSecAttrAccessible as String: accessClass] as CFDictionary)
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.denied(status)
        }
    }

    public func contains(_ key: String) -> Bool {
        (try? value(for: key)) != nil
    }
}
