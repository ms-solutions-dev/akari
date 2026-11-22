import Bedrock
import CryptoKit
import Foundation

/// A profile's PIN: four digits, never in plain text.
///
/// **Salted SHA-256 in the keychain** (`profil.<id>.pin` = `<salt>:<digest>`): A
/// four-digit PIN has 10,000 possibilities — without salt the digest of every PIN
/// would sit in a table; with salt, whoever reads the keychain has to compute anew
/// for each profile. This is no bank, it is the barrier "the child does not end up
/// in dad's shelf" — but plain text would be too little even for that.
///
/// **Three failed attempts, then a 30-second pause** (``PinProtection/Lock``):
/// enough that guessing is no fun, short enough that a parent who mistyped is not
/// locked out. The count survives a restart because it lives in UserDefaults —
/// otherwise "close app, open app" would be the way around the pause.
public enum PinProtection {

    /// The length — four digits, like any remote control.
    public static let length = 4

    /// The most failed attempts allowed before the pause begins.
    public static let failedAttempts = 3

    /// How long the pause lasts.
    public static let pause: TimeInterval = 30

    /// Whether an input is formally a PIN: exactly four digits.
    public static func valid(_ pin: String) -> Bool {
        pin.count == length && pin.allSatisfy(\.isNumber)
    }

    /// Salt and digest for a PIN — a new salt every time.
    public static func mint(_ pin: String) -> String {
        var salt = [UInt8](repeating: 0, count: 16)
        for i in salt.indices { salt[i] = UInt8.random(in: .min ... .max) }
        return hex(salt) + ":" + digest(pin, salt: salt)
    }

    /// Whether the PIN matches the stored entry.
    public static func matches(_ pin: String, to entry: String) -> Bool {
        let share = entry.split(separator: ":", maxSplits: 1).map(String.init)
        guard share.count == 2, let salt = bytes(share[0]) else { return false }
        return digest(pin, salt: salt) == share[1]
    }

    private static func digest(_ pin: String, salt: [UInt8]) -> String {
        var data = Data(salt)
        data.append(contentsOf: Array(pin.utf8))
        return hex(Array(SHA256.hash(data: data)))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            result.append(byte)
            i = j
        }
        return result
    }

    /// The count of failed attempts per profile — in UserDefaults, with a clock for
    /// tests. `@unchecked` because of `UserDefaults`, which is safe from any thread, just
    /// not marked so.
    public struct Lock: @unchecked Sendable {
        private let persistence: UserDefaults
        private let clock: @Sendable () -> Date

        public init(persistence: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { Date() })
        {
            self.persistence = persistence
            self.clock = clock
        }

        private func counterKey(_ profile: Int) -> String {
            Profile.prefix(profile) + "pin.fehlversuche"
        }
        private func untilKey(_ profile: Int) -> String { Profile.prefix(profile) + "pin.gesperrtBis" }

        /// Until when the profile is locked — `nil` if it is free.
        public func lockedUntil(_ profile: Int) -> Date? {
            guard let until = persistence.object(forKey: untilKey(profile)) as? Date, until > clock()
            else {
                return nil
            }
            return until
        }

        /// How many attempts remain before the pause begins.
        public func remaining(_ profile: Int) -> Int {
            max(0, PinProtection.failedAttempts - persistence.integer(forKey: counterKey(profile)))
        }

        /// A failed attempt — the third one locks.
        public func failedAttempt(_ profile: Int) {
            let counter = persistence.integer(forKey: counterKey(profile)) + 1
            if counter >= PinProtection.failedAttempts {
                persistence.set(
                    clock().addingTimeInterval(PinProtection.pause), forKey: untilKey(profile))
                persistence.removeObject(forKey: counterKey(profile))
            } else {
                persistence.set(counter, forKey: counterKey(profile))
            }
        }

        /// After the right attempt — or when the PIN is removed.
        public func erase(_ profile: Int) {
            persistence.removeObject(forKey: counterKey(profile))
            persistence.removeObject(forKey: untilKey(profile))
        }
    }
}
