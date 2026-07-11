import Foundation

/// One compacted stretch of activity: consecutive frames whose on-screen text was
/// near-identical are merged into a single segment (you sit on the same screen for
/// minutes — sending every 2s frame would be mostly duplication).
struct ActivitySegment {
    let start: Date
    let end: Date
    let appHint: String?      // best-guess app/window from the OCR (often the menu-bar line)
    let text: String          // representative screen text
    let tokenCount: Int       // salient OCR tokens — low means the screen wasn't readable as text
    let representativeFrameID: Int64?  // middle frame, used for vision sampling / thumbnails
    var durationSeconds: Double { end.timeIntervalSince(start) }

    /// Real time was spent here but OCR captured little — a candidate for vision sampling.
    var isAmbiguous: Bool {
        tokenCount <= K.visionAmbiguousTokenMax && durationSeconds >= K.visionMinDwellSeconds
    }
}

/// An activity neither OCR nor vision could identify — surfaced to the user to explain.
/// Answers persist and are fed into future analyses so understanding accrues over days.
struct OpenQuestion: Identifiable {
    let id: Int64
    let day: String
    let ts: Double
    let durationSeconds: Double
    let frameID: Int64?
    let hint: String?         // the vision model's partial guess, if any
    let answer: String?
    let answeredAt: Double?
}

/// The model's structured output for one day.
struct DailyAnalysis: Codable {
    struct Observation: Codable {
        let behavior: String     // the repeated low-value behavior
        let category: String     // e.g. "polling-loop", "manual-repetition", "tool-cost", "context-switching"
        let evidence: String     // what was seen that supports it
        let frequency: Int       // times seen today
        let suggestion: String   // concrete optimization (hotkey, script, extension, tool swap)
    }
    let daySummary: String
    let focusAreas: [String]
    let observations: [Observation]

    enum CodingKeys: String, CodingKey {
        case daySummary = "day_summary"
        case focusAreas = "focus_areas"
        case observations
    }
}

/// A persisted ledger entry accumulated across days.
struct LedgerObservation: Identifiable {
    let id: Int64
    let key: String            // normalized behavior, used to merge across days
    var behavior: String
    var category: String
    var suggestion: String
    var evidence: String
    var daysSeen: Int          // distinct days this pattern appeared
    var totalFrequency: Int
    var firstSeen: Double      // unix seconds
    var lastSeen: Double
    var confirmed: Bool        // promoted once daysSeen >= threshold
    var dismissed: Bool

    var isActionable: Bool { confirmed && !dismissed }
}

struct DailyDigest: Identifiable {
    let id: Int64
    let day: String            // "YYYY-MM-DD"
    let createdAt: Double
    let summary: String
    let focusAreas: [String]
    let newlyConfirmed: [LedgerObservation]
}
