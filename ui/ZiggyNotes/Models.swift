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
    var aiAssistance: Bool

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case title
        case callContext = "call_context"
        case summaryGuidelines = "summary_guidelines"
        case summaryStructure = "summary_structure"
        case language
        case repName = "rep_name"
        case aiAssistance = "ai_assistance"
    }

    init(
        meetingId: String,
        title: String,
        callContext: String? = nil,
        summaryGuidelines: String? = nil,
        summaryStructure: String? = nil,
        language: String? = nil,
        repName: String? = nil,
        aiAssistance: Bool = true
    ) {
        self.meetingId = meetingId
        self.title = title
        self.callContext = callContext
        self.summaryGuidelines = summaryGuidelines
        self.summaryStructure = summaryStructure
        self.language = language
        self.repName = repName
        self.aiAssistance = aiAssistance
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
    var attendees: [String]
    var keyPoints: [String]
    var actionItems: [String]
    var nextSteps: [String]
    var feedback: String
    var score: Int

    enum CodingKeys: String, CodingKey {
        case summary, attendees
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case nextSteps = "next_steps"
        case feedback
        case score
    }

    // Tolerate older payloads that predate attendees/feedback/score.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        nextSteps = try c.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        feedback = try c.decodeIfPresent(String.self, forKey: .feedback) ?? ""
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
    }
}

/// Mirrors `ziggy.models.TranscriptRow`.
struct TranscriptRowDTO: Codable, Sendable, Identifiable, Hashable {
    var index: Int
    var speaker: String
    var text: String
    var startSeconds: Double
    var endSeconds: Double
    var capturedAt: Double

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, speaker, text
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case capturedAt = "captured_at"
    }

    // Tolerate rows from before captured_at existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        endSeconds = try c.decodeIfPresent(Double.self, forKey: .endSeconds) ?? 0
        capturedAt = try c.decodeIfPresent(Double.self, forKey: .capturedAt) ?? 0
    }
}

/// Mirrors `ziggy.models.SuggestionRow`.
struct SuggestionRowDTO: Codable, Sendable, Hashable {
    var id: String
    var atChunk: Int
    var kind: String
    var title: String
    var detail: String
    var priority: String

    enum CodingKeys: String, CodingKey {
        case id
        case atChunk = "at_chunk"
        case kind, title, detail, priority
    }

    // Tolerate payloads that predate the stable id / omit at_chunk.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        atChunk = try c.decodeIfPresent(Int.self, forKey: .atChunk) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "bring_up"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
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
