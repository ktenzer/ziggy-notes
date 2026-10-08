import Foundation

// MARK: - Domain models for the in-process Swift worker.
//
// Same JSON snake_case field names as the wire contract so query results decode
// byte-compatibly into the app's DTOs in `Models.swift`.
//
// `MeetingInput` and `UpdatesCursor` are already declared in the app target
// (`Models.swift`) and are reused here to avoid duplicate type definitions.
// Stream event types are intentionally dropped (the UI polls `get_updates`).

/// Audio source of a transcript line. `mic` = local microphone (always the
/// Temporal rep); `output` = system/meeting audio (usually the customer).
enum ZiggySource {
    static let mic = "mic"
    static let output = "output"
}

/// Source-based default speaker label. The local microphone is always the app
/// user ("You"); remote/meeting audio is "Other" until a name is identified
/// (it may be the customer OR another Temporal colleague on the call).
func defaultLabel(_ source: String) -> String {
    source == ZiggySource.mic ? "You" : "Other"
}

/// One transcribed window from one audio source. Sent to the workflow as the
/// `add_transcript_chunk` signal. Mirrors `ziggy.models.TranscriptChunk`.
struct TranscriptChunk: Codable, Sendable, Hashable {
    var index: Int
    var source: String
    var speaker: String
    var text: String
    var startSeconds: Double
    var endSeconds: Double

    enum CodingKeys: String, CodingKey {
        case index, source, speaker, text
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }

    init(index: Int, source: String, speaker: String = "", text: String,
         startSeconds: Double = 0, endSeconds: Double = 0) {
        self.index = index
        self.source = source
        self.speaker = speaker
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Input to the `capture_audio` activity. Mirrors `ziggy.models.CaptureInput`.
struct CaptureInput: Codable, Sendable {
    var meetingId: String
    var language: String?

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case language
    }
}

/// Result of `capture_audio`. Mirrors `ziggy.models.CaptureResult`.
struct CaptureResult: Codable, Sendable {
    var chunkCount: Int
    var durationSeconds: Double
    var stopReason: String
    var micCaptured: Bool
    var systemCaptured: Bool

    enum CodingKeys: String, CodingKey {
        case chunkCount = "chunk_count"
        case durationSeconds = "duration_seconds"
        case stopReason = "stop_reason"
        case micCaptured = "mic_captured"
        case systemCaptured = "system_captured"
    }

    init(chunkCount: Int = 0, durationSeconds: Double = 0, stopReason: String = "unknown",
         micCaptured: Bool = false, systemCaptured: Bool = false) {
        self.chunkCount = chunkCount
        self.durationSeconds = durationSeconds
        self.stopReason = stopReason
        self.micCaptured = micCaptured
        self.systemCaptured = systemCaptured
    }
}

/// A single active-listening suggestion. Mirrors `ziggy.models.Observation`.
/// (Named `ZiggyObservation` to avoid clashing with the `Observation` framework
/// that backs the `@Observable` macro used in the app target.)
struct ZiggyObservation: Codable, Sendable, Hashable {
    var id: String
    var kind: String
    var title: String
    var detail: String
    var priority: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, priority
    }

    init(id: String = "", kind: String = "bring_up", title: String,
         detail: String = "", priority: String = "medium") {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "bring_up"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
    }
}

/// Input to `analyze_conversation`. Mirrors `ziggy.models.AnalysisInput`.
struct AnalysisInput: Codable, Sendable {
    var title: String
    var transcript: String
    var callContext: String?
    var currentSuggestions: [ZiggyObservation]
    var maxSuggestions: Int

    enum CodingKeys: String, CodingKey {
        case title, transcript
        case callContext = "call_context"
        case currentSuggestions = "current_suggestions"
        case maxSuggestions = "max_suggestions"
    }
}

/// Output of `analyze_conversation`. Mirrors `ziggy.models.AnalysisResult`.
struct AnalysisResult: Codable, Sendable {
    var observations: [ZiggyObservation]

    init(observations: [ZiggyObservation] = []) { self.observations = observations }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observations = try c.decodeIfPresent([ZiggyObservation].self, forKey: .observations) ?? []
    }
    enum CodingKeys: String, CodingKey { case observations }
}

/// One speaker attribution. Mirrors `ziggy.models.SpeakerAssignment`.
struct SpeakerAssignment: Codable, Sendable {
    var index: Int
    var label: String
    var name: String?
    var org: String

    init(index: Int, label: String, name: String? = nil, org: String = "unknown") {
        self.index = index; self.label = label; self.name = name; self.org = org
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? -1
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        org = try c.decodeIfPresent(String.self, forKey: .org) ?? "unknown"
    }
    enum CodingKeys: String, CodingKey { case index, label, name, org }
}

/// Input to `identify_speakers`. Mirrors `ziggy.models.IdentityInput`.
struct IdentityInput: Codable, Sendable {
    var title: String
    var transcript: String
    var callContext: String?
    var repName: String?

    enum CodingKeys: String, CodingKey {
        case title, transcript
        case callContext = "call_context"
        case repName = "rep_name"
    }
}

/// Output of `identify_speakers`. Mirrors `ziggy.models.IdentityResult`.
struct IdentityResult: Codable, Sendable {
    var assignments: [SpeakerAssignment]
    var roster: [String]

    init(assignments: [SpeakerAssignment] = [], roster: [String] = []) {
        self.assignments = assignments; self.roster = roster
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try c.decodeIfPresent([SpeakerAssignment].self, forKey: .assignments) ?? []
        roster = try c.decodeIfPresent([String].self, forKey: .roster) ?? []
    }
    enum CodingKeys: String, CodingKey { case assignments, roster }
}

/// Input to `summarize_meeting`. Mirrors `ziggy.models.SummaryInput`.
struct SummaryInput: Codable, Sendable {
    var title: String
    var transcript: String
    var callContext: String?
    var guidelines: String?
    var structure: String?

    enum CodingKeys: String, CodingKey {
        case title, transcript
        case callContext = "call_context"
        case guidelines, structure
    }
}

/// Final meeting summary + coaching. Mirrors `ziggy.models.MeetingSummary`.
struct MeetingSummary: Codable, Sendable, Hashable {
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var nextSteps: [String]
    var feedback: String
    var score: Int

    enum CodingKeys: String, CodingKey {
        case summary
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case nextSteps = "next_steps"
        case feedback, score
    }

    init(summary: String = "", keyPoints: [String] = [], actionItems: [String] = [],
         nextSteps: [String] = [], feedback: String = "", score: Int = 0) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.nextSteps = nextSteps
        self.feedback = feedback
        self.score = score
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        nextSteps = try c.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        feedback = try c.decodeIfPresent(String.self, forKey: .feedback) ?? ""
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
    }
}

/// Input to `create_google_doc`. Mirrors `ziggy.models.GoogleDocInput`.
struct GoogleDocInput: Codable, Sendable {
    var meetingId: String
    var title: String
    var summary: MeetingSummary
    var transcript: String

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case title, summary, transcript
    }
}

/// Reference to the produced (stubbed) Google Doc. Mirrors `ziggy.models.GoogleDocRef`.
struct GoogleDocRef: Codable, Sendable {
    var docId: String
    var url: String
    var localPath: String?

    enum CodingKeys: String, CodingKey {
        case docId = "doc_id"
        case url
        case localPath = "local_path"
    }

    init(docId: String, url: String, localPath: String? = nil) {
        self.docId = docId; self.url = url; self.localPath = localPath
    }
}

/// Workflow result. Mirrors `ziggy.models.MeetingResult`.
struct MeetingResult: Codable, Sendable {
    var meetingId: String
    var title: String
    var chunkCount: Int
    var stopReason: String
    var transcript: String
    var summary: MeetingSummary
    var googleDoc: GoogleDocRef
    var roster: [String]

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case title
        case chunkCount = "chunk_count"
        case stopReason = "stop_reason"
        case transcript, summary
        case googleDoc = "google_doc"
        case roster
    }
}

/// Transcript row returned by `get_updates`. Mirrors `ziggy.models.TranscriptRow`.
struct TranscriptRow: Codable, Sendable {
    var index: Int
    var speaker: String
    var text: String
    var startSeconds: Double
    var endSeconds: Double

    enum CodingKeys: String, CodingKey {
        case index, speaker, text
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

/// Suggestion row returned by `get_updates`. Mirrors `ziggy.models.SuggestionRow`.
struct SuggestionRow: Codable, Sendable {
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

    init(id: String = "", atChunk: Int = 0, kind: String = "bring_up",
         title: String, detail: String = "", priority: String = "medium") {
        self.id = id; self.atChunk = atChunk; self.kind = kind
        self.title = title; self.detail = detail; self.priority = priority
    }
}

/// Snapshot returned by the `get_updates` query. Mirrors `ziggy.models.MeetingUpdates`.
struct MeetingUpdates: Codable, Sendable {
    var state: String
    var stopRequested: Bool
    var abortRequested: Bool
    var chunkCount: Int
    var suggestionCount: Int
    var transcript: [TranscriptRow]
    var suggestions: [SuggestionRow]
    var labels: [String: String]
    var roster: [String]
    var summary: MeetingSummary?

    enum CodingKeys: String, CodingKey {
        case state
        case stopRequested = "stop_requested"
        case abortRequested = "abort_requested"
        case chunkCount = "chunk_count"
        case suggestionCount = "suggestion_count"
        case transcript, suggestions, labels, roster, summary
    }
}
