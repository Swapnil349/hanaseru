import Foundation

/// One observed mistake. The app aggregates these into a personal error database (spec §30).
public struct MistakeObservation: Codable, Equatable, Sendable {
    public var type: MistakeType
    public var itemID: String?
    public var said: String
    public var correction: String
    public var explanation: String
    public var date: Date

    public init(type: MistakeType, itemID: String?, said: String, correction: String, explanation: String, date: Date) {
        self.type = type
        self.itemID = itemID
        self.said = said
        self.correction = correction
        self.explanation = explanation
        self.date = date
    }

    /// Stable aggregation key: the same kind of error with the same fix counts as a recurrence.
    public var aggregationKey: String { "\(type.rawValue)|\(correction)" }
}

/// Aggregated view of a recurring mistake.
public struct MistakeSummary: Equatable, Sendable {
    public var type: MistakeType
    public var correction: String
    public var explanation: String
    public var lastSaid: String
    public var itemID: String?
    public var occurrences: Int
    public var lastSeen: Date

    public init(type: MistakeType, correction: String, explanation: String, lastSaid: String, itemID: String?, occurrences: Int, lastSeen: Date) {
        self.type = type
        self.correction = correction
        self.explanation = explanation
        self.lastSaid = lastSaid
        self.itemID = itemID
        self.occurrences = occurrences
        self.lastSeen = lastSeen
    }
}
