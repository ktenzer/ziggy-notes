import Foundation
import SwiftData

/// Lifecycle states for a meeting as tracked locally.
enum MeetingState: String, Codable {
    case recording      // workflow running, actively listening
    case summarizing    // stop requested, summary being produced
    case completed      // workflow finished, summary available
    case stopped        // finished without a summary
    case error
    case unknown

    /// Maps the workflow's `state` string (from `get_updates`) into a local state.
    /// The Python workflow emits: starting, analyzing, recording, summarizing, completed.
    /// Anything that isn't explicitly terminal/summarizing is treated as live
    /// ("recording") so an in-progress workflow is never mistaken for dead.
    static func fromWorkflow(_ s: String) -> MeetingState {
        switch s.lowercased() {
        case "completed", "done", "finished": return .completed
        case "error", "failed": return .error
        case "summarizing", "stopping", "finalizing": return .summarizing
        default: return .recording   // starting / analyzing / recording / listening / running …
        }
    }

    var isLive: Bool { self == .recording || self == .summarizing }

    /// Terminal states are never polled again.
    var isTerminal: Bool { self == .completed || self == .stopped || self == .error }
}

@Model
final class MeetingRecord {
    @Attribute(.unique) var meetingId: String
    var title: String
    var createdAt: Date
    var stateRaw: String

    // Summary fields
    var summaryText: String
    var attendees: [String] = []
    var keyPoints: [String]
    var actionItems: [String]
    var nextSteps: [String]
    // Role-aware coaching feedback + performance score (1-10; 0 = unscored).
    var feedbackText: String = ""
    var score: Int = 0

    var roster: [String]

    // Set when the user presses Stop, so the UI stays in "summarizing" until the
    // workflow actually finishes (prevents a race from flipping it back to live).
    var stopRequested: Bool = false

    // Polling cursors (so we only fetch new rows/suggestions).
    var lastChunk: Int
    var lastSuggestion: Int

    @Relationship(deleteRule: .cascade, inverse: \TranscriptLineRecord.meeting)
    var lines: [TranscriptLineRecord]

    @Relationship(deleteRule: .cascade, inverse: \SuggestionRecord.meeting)
    var suggestions: [SuggestionRecord]

    init(meetingId: String, title: String, createdAt: Date = .now, state: MeetingState = .recording) {
        self.meetingId = meetingId
        self.title = title
        self.createdAt = createdAt
        self.stateRaw = state.rawValue
        self.summaryText = ""
        self.attendees = []
        self.keyPoints = []
        self.actionItems = []
        self.nextSteps = []
        self.feedbackText = ""
        self.score = 0
        self.roster = []
        self.stopRequested = false
        self.lastChunk = 0
        self.lastSuggestion = 0
        self.lines = []
        self.suggestions = []
    }

    var state: MeetingState {
        get { MeetingState(rawValue: stateRaw) ?? .unknown }
        set { stateRaw = newValue.rawValue }
    }

    var hasSummary: Bool { !summaryText.isEmpty || !keyPoints.isEmpty || !actionItems.isEmpty || !nextSteps.isEmpty }

    /// Full transcript rendered as "Speaker: text" lines, ordered by index.
    var transcriptText: String {
        lines.sorted { $0.index < $1.index }
            .map { line in
                let speaker = line.speaker.isEmpty ? "Speaker" : line.speaker
                return "\(speaker): \(line.text)"
            }
            .joined(separator: "\n")
    }
}

@Model
final class TranscriptLineRecord {
    var index: Int
    var speaker: String
    var text: String
    var startSeconds: Double
    // Wall-clock capture time (seconds since the Unix epoch); 0 when unknown.
    var capturedAt: Double = 0
    var meeting: MeetingRecord?

    init(index: Int, speaker: String, text: String, startSeconds: Double, capturedAt: Double = 0) {
        self.index = index
        self.speaker = speaker
        self.text = text
        self.startSeconds = startSeconds
        self.capturedAt = capturedAt
    }

    /// Actual time of day this line was captured, in the user's timezone/locale
    /// (e.g. "12:55 PM"). Falls back to elapsed `m:ss` for rows captured before
    /// wall-clock timestamps were recorded.
    var timestamp: String {
        if capturedAt > 0 {
            return Date(timeIntervalSince1970: capturedAt)
                .formatted(date: .omitted, time: .shortened)
        }
        let total = Int(startSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@Model
final class SuggestionRecord {
    // Stable id from the backend active-suggestion board (used to reconcile
    // update/remove across polls). Empty for records created before this field.
    var suggestionId: String = ""
    var atChunk: Int
    var kind: String
    var title: String
    var detail: String
    var priority: String
    var createdAt: Date
    var meeting: MeetingRecord?

    init(suggestionId: String = "", atChunk: Int, kind: String, title: String, detail: String, priority: String, createdAt: Date = .now) {
        self.suggestionId = suggestionId
        self.atChunk = atChunk
        self.kind = kind
        self.title = title
        self.detail = detail
        self.priority = priority
        self.createdAt = createdAt
    }

    /// Sort key: high (0) before medium (1) before low (2).
    var priorityRank: Int {
        switch priority.lowercased() {
        case "high": return 0
        case "medium": return 1
        default: return 2
        }
    }
}
