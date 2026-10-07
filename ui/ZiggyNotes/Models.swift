import Foundation

// MARK: - Codable DTOs mirroring the Python/pydantic models.
//
// The Swift Temporal SDK's default `DataConverter` encodes/decodes with a plain
// `JSONEncoder`/`JSONDecoder` (no key-conversion strategy), and the Python side uses
// pydantic with snake_case field names. We therefore declare explicit snake_case
// `CodingKeys` so payloads round-trip byte-compatibly between the two SDKs.

/// Input passed to `MeetingWorkflow` when starting a new note.
/// Mirrors `ziggy.models.MeetingInput`.
struct MeetingInput: Codable, Sendable {
    var meetingId: String
    var title: String
    var callContext: String?
    var summaryGuidelines: String?
    var summaryStructure: String?
    var language: String?
    var repName: String?

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case title
        case callContext = "call_context"
        case summaryGuidelines = "summary_guidelines"
        case summaryStructure = "summary_structure"
        case language
        case repName = "rep_name"
    }

    init(
        meetingId: String,
        title: String,
        callContext: String? = nil,
        summaryGuidelines: String? = nil,
        summaryStructure: String? = nil,
        language: String? = nil,
        repName: String? = nil
    ) {
        self.meetingId = meetingId
        self.title = title
        self.callContext = callContext
        self.summaryGuidelines = summaryGuidelines
        self.summaryStructure = summaryStructure
        self.language = language
        self.repName = repName
    }
}

/// Cursor passed to the `get_updates` query. Mirrors `ziggy.models.UpdatesCursor`.
/// Sent as a single argument so the Swift parameter-pack call is unambiguous.
struct UpdatesCursor: Codable, Sendable {
    var sinceChunk: Int
    var sinceSuggestion: Int

    enum CodingKeys: String, CodingKey {
        case sinceChunk = "since_chunk"
        case sinceSuggestion = "since_suggestion"
    }
}

/// Mirrors `ziggy.models.MeetingSummary`.
struct MeetingSummaryDTO: Codable, Sendable, Hashable {
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var nextSteps: [String]

    enum CodingKeys: String, CodingKey {
        case summary
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case nextSteps = "next_steps"
    }
}

/// Mirrors `ziggy.models.TranscriptRow`.
struct TranscriptRowDTO: Codable, Sendable, Identifiable, Hashable {
    var index: Int
    var speaker: String
    var text: String
    var startSeconds: Double
    var endSeconds: Double

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, speaker, text
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

/// Mirrors `ziggy.models.SuggestionRow`.
struct SuggestionRowDTO: Codable, Sendable, Hashable {
    var atChunk: Int
    var kind: String
    var title: String
    var detail: String
    var priority: String

    enum CodingKeys: String, CodingKey {
        case atChunk = "at_chunk"
        case kind, title, detail, priority
    }
}

/// Result of the `get_updates` query. Mirrors `ziggy.models.MeetingUpdates`.
struct MeetingUpdatesDTO: Codable, Sendable {
    var state: String
    var stopRequested: Bool
    var abortRequested: Bool
    var chunkCount: Int
    var suggestionCount: Int
    var transcript: [TranscriptRowDTO]
    var suggestions: [SuggestionRowDTO]
    var labels: [String: String]
    var roster: [String]
    var summary: MeetingSummaryDTO?

    enum CodingKeys: String, CodingKey {
        case state
        case stopRequested = "stop_requested"
        case abortRequested = "abort_requested"
        case chunkCount = "chunk_count"
        case suggestionCount = "suggestion_count"
        case transcript, suggestions, labels, roster, summary
    }
}
