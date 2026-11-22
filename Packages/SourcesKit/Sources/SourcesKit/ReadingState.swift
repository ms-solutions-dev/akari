import Foundation

/// Where someone is in a title — a wrapper around three incomparable positions
/// and the fraction that all of them share.
///
/// **The position is not translatable, the fraction is:** Komga counts pages, Grimmory writes
/// an EPUB CFI, Audiobookshelf seconds. For "Continue reading across three servers",
/// `fraction + timestamp + completed` is enough; the position is needed only by the reader
/// that wrote it.
///
/// `completed` is a field of its own and not a consequence of `fraction == 1`: Komga sets
/// `completed` with the last page, Grimmory with `dateFinished`, and an audiobook standing at
/// 99.4 % is finished. What the server says goes.
public struct ReadingState: Sendable, Codable, Hashable {

    /// The three kinds of position — one per world.
    public enum Position: Sendable, Codable, Hashable {
        /// Page `n` of `from`, 1-based as in Komga.
        case page(Int, from: Int)
        /// EPUB CFI plus the fraction the renderer measured with it — it cannot be
        /// computed from the CFI alone.
        case position(cfi: String, fraction: Double)
        /// Second `s` of `from` — audiobook.
        case second(TimeInterval, from: TimeInterval)
        /// Only the fraction — what an extract knows about a title whose exact
        /// position only ``Source/progress(_:)`` delivers (Grimmory's list gives
        /// `readProgress`, the CFI only the detail).
        case fraction(Double)

        enum CodingKeys: String, CodingKey, CaseIterable {
            case page = "seite"
            case position
            case second = "sekunde"
            case fraction = "anteil"
        }
        enum PageCodingKeys: String, CodingKey, CaseIterable {
            case _0
            case from = "von"
        }
        enum PositionCodingKeys: String, CodingKey, CaseIterable {
            case cfi
            case fraction = "anteil"
        }
        enum SecondCodingKeys: String, CodingKey, CaseIterable {
            case _0
            case from = "von"
        }
        enum FractionCodingKeys: String, CodingKey, CaseIterable {
            case _0
        }
    }

    public let position: Position
    public let timestamp: Date
    /// The device name as the server knows it — empty for Komga, for Grimmory only
    /// via KOReader; the app writes its own when saving.
    public let device: String?
    public let completed: Bool

    public init(position: Position, timestamp: Date, device: String? = nil, completed: Bool = false) {
        self.position = position
        self.timestamp = timestamp
        self.device = device
        self.completed = completed
    }

    /// 0 … 1, computed from the position — the one number all three worlds share.
    public var fraction: Double {
        switch position {
        case .page(let n, let from):
            return from > 0 ? min(max(Double(n) / Double(from), 0), 1) : 0
        case .position(_, let fraction):
            return min(max(fraction, 0), 1)
        case .second(let s, let from):
            return from > 0 ? min(max(s / from, 0), 1) : 0
        case .fraction(let fraction):
            return min(max(fraction, 0), 1)
        }
    }

    /// Started, but not finished — the criterion for "Continue reading".
    public var started: Bool { !completed && fraction > 0 }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case position
        case timestamp = "zeitstempel"
        case device = "geraet"
        case completed = "abgeschlossen"
    }
}
