import Foundation
import SourcesKit

/// What applies before a reader opens when device and server differ.
public enum Resolution: Sendable, Equatable {
    /// From the start: never begun, anywhere.
    case begin
    /// This state, no questions asked. `supply` says the server does not have it yet;
    /// the caller writes it on the next contact.
    case take(ReadingState, supply: Bool)
    /// Reading continued elsewhere: the conflict sheet asks. `here` is this device's
    /// state, `there` the server's.
    case question(here: ReadingState, there: ReadingState)

    /// A word for the log.
    public var short: String {
        switch self {
        case .begin: "begin"
        case .take(_, let supply): supply ? "here, supply" : "server"
        case .question: "question"
        }
    }

    /// The state the reader opens with as long as nobody has been asked.
    public var state: ReadingState? {
        switch self {
        case .begin: nil
        case .take(let s, _): s
        case .question(let here, _): here
        }
    }
}

/// The server is the truth, except in the one case where it surprises you.
///
/// **Forward silently, ask on a step back:** whatever this device has read further and
/// the server does not know yet is supplied silently; your own reading needs no
/// permission. If the server is *further along* than what was last here, and that is not
/// this device's own last write, then somebody read elsewhere (the iPad, the partner on
/// the same account): the sheet asks instead of silently moving the reader forty pages
/// ahead. If the server is *behind* and also newer (somebody reset the state), the
/// server wins: it is the truth, and a reset is intentional.
///
/// **The tolerance:** one percent. Grimmory rounds the fraction, Komga counts pages; a
/// state that differs by half a page is the same state.
public enum ConflictRule {

    public static let tolerance = 0.01

    /// - Parameters:
    ///   - local: what this device knows, from the shelf, including what is still pending
    ///   - server: the fresh state from the server; `nil` means never begun or not
    ///     reachable (then `reachable: false`)
    ///   - own: what this device last wrote itself. The rule uses it to recognise its
    ///     own state on the server, since none of the three servers stores a device name
    ///   - reachable: whether the server answered at all
    public static func decide(
        local: ReadingState?, server: ReadingState?, own: ReadingState? = nil, reachable: Bool = true
    ) -> Resolution {
        guard reachable else {
            return local.map { .take($0, supply: true) } ?? .begin
        }
        switch (local, server) {
        case (nil, nil):
            return .begin
        case (let local?, nil):
            // The server knows nothing: whatever is here goes there.
            return .take(local, supply: true)
        case (nil, let server?):
            // Never opened here: the server is the truth, no questions asked.
            return .take(server, supply: false)
        case (let local?, let server?):
            if equal(local, server) { return .take(server, supply: false) }
            if let own, equal(own, server) {
                // The server carries our own last write; something newer is here.
                return .take(local, supply: true)
            }
            if server.timestamp <= local.timestamp {
                // Newer here, forward or back: supply it silently.
                return .take(local, supply: true)
            }
            if server.fraction > local.fraction + tolerance || (server.completed && !local.completed) {
                return .question(here: local, there: server)
            }
            return .take(server, supply: false)
        }
    }

    /// The same state, within the tolerance.
    public static func equal(_ a: ReadingState, _ b: ReadingState) -> Bool {
        abs(a.fraction - b.fraction) <= tolerance && a.completed == b.completed
    }
}
