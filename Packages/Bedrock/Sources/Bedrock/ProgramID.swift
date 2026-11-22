import Foundation

/// Who runs here: the one place where the foundation learns the name of the
/// program standing on it.
///
/// **Why it exists:** the bundle identifier used to be written out in six places
/// in the source, as the subsystem of the logs, as the service in the keychain,
/// as the prefix of the trace files. A foundation that carries several programs
/// must not call any of them by name. It reads the bundle identifier and derives
/// the rest from it.
///
/// **For existing installations nothing changes:** the bundle identifier is the
/// very literal that stood there before. Keychain entries and trace files on
/// set-up devices therefore stay where they are.
public enum ProgramID {

    /// The bundle identifier of the running program, e.g. `dev.ms-solutions.akari`.
    /// Under `swift test` on the computer it is that of the test tool; tests name
    /// their services and files themselves.
    public static let bundle: String =
        Bundle.main.bundleIdentifier ?? "dev.ms-solutions.unbenannt"

    /// The last component of the identifier, lowercased: `akari`. Prefix for files
    /// the program puts in the cache.
    public static let shortName: String =
        bundle.split(separator: ".").last.map { String($0).lowercased() } ?? "programm"
}
