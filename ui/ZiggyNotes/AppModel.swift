import Foundation
import SwiftData
import Observation

/// A selectable destination in the sidebar. Meetings are addressed by id; Settings
/// and Worker Logs are first-class in-app pages (not popup windows).
enum SidebarRoute: Hashable {
    case meeting(String)
    case settings
    case workerLogs
}

/// Central orchestrator: boots the Python worker, connects the Temporal client,
/// starts/stops meetings, reconnects to running meetings on launch, and runs the
/// 10-second `get_updates` polling loop that merges live data into SwiftData.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case requestingMic
        case startingWorker
        case connecting
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    var banner: String?

    /// Set by menu commands (e.g. ⌘,) to ask the main view to navigate somewhere.
    /// `ContentView` observes this, applies it to its selection, then clears it.
    var pendingRoute: SidebarRoute?

    let settings = Settings()
    let worker = WorkerManager()
    private(set) var client: ZiggyClient
    private(set) var config: TemporalConfig

    /// Meeting the user is currently viewing live (active meeting screen).
    var activeMeetingId: String?

    /// One "ask anything" question/answer exchange (in-memory, per live meeting).
    struct AskExchange: Identifiable {
        let id: UUID
        let question: String
        var answer: String
        var pending: Bool
    }
    /// In-memory ask thread per meeting id (not persisted to the note).
    var askThreads: [String: [AskExchange]] = [:]
    /// True while an ask workflow is in flight for a meeting (blocks new questions).
    var askPending: [String: Bool] = [:]
    /// Monotonic per-meeting question counter, used to build the workflow id.
    private var askSeq: [String: Int] = [:]

    /// Suggestion ids the user dismissed locally. Kept so the 5s poll doesn't
    /// flicker a dismissed card back before the workflow drops it, and so a second
    /// "×" click can't fire a duplicate signal.
    private var dismissedSuggestionIds: Set<String> = []

    private var modelContext: ModelContext?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(5)

    init() {
        let cfg = TemporalConfig.from(settings: settings)
        self.config = cfg
        self.client = ZiggyClient(config: cfg)
    }

    func attach(context: ModelContext) {
        self.modelContext = context
    }

    var isReady: Bool { phase == .ready }

    /// True when a note is currently live (recording or summarizing). Only one note
    /// may run at a time.
    func hasLiveMeeting() -> Bool {
        guard let context = modelContext else { return false }
        let meetings = (try? context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        return meetings.contains { $0.state.isLive }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        // Rebuild connection + client from the current settings each time.
        config = .from(settings: settings)
        client = ZiggyClient(config: config)

        phase = .requestingMic
        _ = await worker.requestMicrophoneAccess()
        // Screen Recording permission is needed for hands-off system-audio capture
        // (the customer side) via ScreenCaptureKit. Best-effort prompt on first run.
        worker.requestScreenCaptureAccess()

        phase = .startingWorker
        do {
            try await worker.start(temporal: config, worker: settings.workerConfig())
        } catch {
            phase = .failed("Worker did not start.\n\n\(error)")
            return
        }

        phase = .connecting
        do {
            try await client.connect()
        } catch {
            phase = .failed("Could not connect to Temporal at \(config.address).\n\n\(error)")
            return
        }

        phase = .ready
        await reconnectRunningMeetings()
        startPolling()
    }

    /// Applies updated settings: restarts the in-process worker and reconnects.
    func reload() async {
        pollTask?.cancel()
        pollTask = nil
        worker.stop()
        await client.shutdown()
        await bootstrap()
    }

    func shutdown() {
        pollTask?.cancel()
        Task { await client.shutdown() }
        worker.stop()
    }

    // MARK: - Reconnect

    /// Re-attach to any meetings that were still live when the app last ran.
    private func reconnectRunningMeetings() async {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<MeetingRecord>()
        let meetings = (try? context.fetch(descriptor)) ?? []
        // Reconcile every non-terminal meeting (includes any legacy "unknown" rows).
        for meeting in meetings where !meeting.state.isTerminal {
            await pollOnce(meeting)
        }
    }

    // MARK: - Start / stop

    @discardableResult
    func startNewMeeting(title: String, repName: String?) async -> MeetingRecord? {
        guard let context = modelContext else { return nil }

        // Enforce a single running note.
        if hasLiveMeeting() {
            banner = "A note is already running. Stop it before starting a new one."
            return nil
        }

        let meetingId = UUID().uuidString.prefix(8).lowercased()
        let input = MeetingInput(
            meetingId: String(meetingId),
            title: title.isEmpty ? "Temporal Sales Call" : title,
            repName: (repName?.isEmpty == false) ? repName : nil,
            aiAssistance: settings.aiAssistance
        )

        let record = MeetingRecord(meetingId: String(meetingId), title: input.title, state: .recording)
        context.insert(record)
        try? context.save()

        do {
            _ = try await client.startMeeting(input)
        } catch {
            record.state = .error
            try? context.save()
            banner = "Failed to start meeting: \(error)"
            return record
        }

        activeMeetingId = record.meetingId
        startPolling()
        return record
    }

    /// Dismiss a suggestion the user isn't concerned about: remove it locally for
    /// instant feedback, then signal the workflow to suppress it (and equivalents)
    /// for the rest of the meeting. Server state stays authoritative via polling.
    func dismissSuggestion(_ meeting: MeetingRecord, _ suggestion: SuggestionRecord) async {
        let sid = suggestion.suggestionId
        // Guard against double-dismiss: a second click (before the board refreshes)
        // must not send another signal.
        if !sid.isEmpty {
            guard !dismissedSuggestionIds.contains(sid) else { return }
            dismissedSuggestionIds.insert(sid)
        }
        // Remove immediately for instant feedback; the dismissed-id set keeps the
        // poll from re-inserting it before the workflow drops it.
        meeting.suggestions.removeAll { $0 === suggestion }
        modelContext?.delete(suggestion)
        try? modelContext?.save()
        guard !sid.isEmpty else { return }
        do {
            try await client.dismissSuggestion(meetingId: meeting.meetingId, suggestionId: sid)
        } catch {
            if !ZiggyClient.isGone(error) {
                banner = "Failed to dismiss suggestion: \(error)"
            }
        }
    }

    /// Ask Ziggy a free-form question about the live meeting. Runs a dedicated
    /// ask workflow (signal-with-start), waits for its answer, and blocks further
    /// questions for this meeting until it returns.
    func ask(_ meeting: MeetingRecord, question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let mid = meeting.meetingId
        guard askPending[mid] != true else { return }

        let seq = (askSeq[mid] ?? 0) + 1
        askSeq[mid] = seq
        askPending[mid] = true

        let exchangeId = UUID()
        var thread = askThreads[mid] ?? []
        thread.append(AskExchange(id: exchangeId, question: q, answer: "", pending: true))
        askThreads[mid] = thread

        // Snapshot transcript + guidance to ground the answer.
        let transcript = meeting.transcriptText
        let guidance = meeting.suggestions
            .sorted { ($0.priorityRank, $0.createdAt) < ($1.priorityRank, $1.createdAt) }
            .map { "- [\($0.priority)] (\($0.kind)) \($0.title): \($0.detail)" }
            .joined(separator: "\n")

        do {
            let answer = try await client.askQuestion(
                meetingId: mid, title: meeting.title, seq: seq,
                question: q, transcript: transcript, guidance: guidance
            )
            updateExchange(mid, exchangeId, answer: answer, pending: false)
        } catch {
            updateExchange(mid, exchangeId,
                           answer: "Sorry — I couldn't answer that right now (\(error)).",
                           pending: false)
        }
        askPending[mid] = false
    }

    private func updateExchange(_ mid: String, _ id: UUID, answer: String, pending: Bool) {
        guard var thread = askThreads[mid], let idx = thread.firstIndex(where: { $0.id == id }) else { return }
        thread[idx].answer = answer
        thread[idx].pending = pending
        askThreads[mid] = thread
    }

    func stopMeeting(_ meeting: MeetingRecord, abort: Bool = false) async {
        meeting.stopRequested = true
        meeting.state = .summarizing
        try? modelContext?.save()
        do {
            try await client.stopMeeting(meetingId: meeting.meetingId, abort: abort)
            // Pull current state/summary; polling continues every 5s until completed.
            await pollOnce(meeting)
        } catch {
            if ZiggyClient.isGone(error) {
                // The workflow is already finished/terminated — reconcile locally so
                // the note always leaves the running state.
                finalizeGone(meeting)
            } else {
                // Allow another attempt.
                meeting.stopRequested = false
                meeting.state = .recording
                try? modelContext?.save()
                banner = "Failed to send stop: \(error)"
            }
        }
    }

    /// Deletes a note. If it's still running, aborts the workflow first (best-effort)
    /// so we don't leave an orphaned execution behind.
    func deleteMeeting(_ meeting: MeetingRecord) async {
        if meeting.state.isLive {
            try? await client.stopMeeting(meetingId: meeting.meetingId, abort: true)
        }
        if activeMeetingId == meeting.meetingId { activeMeetingId = nil }
        modelContext?.delete(meeting)
        try? modelContext?.save()
    }

    /// Marks a meeting whose workflow no longer exists as finished.
    private func finalizeGone(_ meeting: MeetingRecord) {
        meeting.state = meeting.hasSummary ? .completed : .stopped
        try? modelContext?.save()
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollTick()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    private func pollTick() async {
        guard let context = modelContext else { return }
        let meetings = (try? context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        let pending = meetings.filter { !$0.state.isTerminal }
        for meeting in pending {
            await pollOnce(meeting)
        }
    }

    private func pollOnce(_ meeting: MeetingRecord) async {
        do {
            let updates = try await client.getUpdates(
                meetingId: meeting.meetingId,
                sinceChunk: meeting.lastChunk,
                sinceSuggestion: meeting.lastSuggestion
            )
            guard let updates else {
                // Workflow no longer exists.
                meeting.state = meeting.hasSummary ? .completed : .stopped
                try? modelContext?.save()
                return
            }
            merge(updates, into: meeting)
        } catch {
            banner = "Polling error: \(error)"
        }
    }

    private func merge(_ updates: MeetingUpdatesDTO, into meeting: MeetingRecord) {
        guard let context = modelContext else { return }

        // Upgrade speaker labels on existing lines as names get identified.
        if !updates.labels.isEmpty {
            for line in meeting.lines {
                if let label = updates.labels[String(line.index)], !label.isEmpty {
                    line.speaker = label
                }
            }
        }

        // Insert / update transcript rows.
        for row in updates.transcript {
            if let existing = meeting.lines.first(where: { $0.index == row.index }) {
                existing.text = row.text
                if !row.speaker.isEmpty { existing.speaker = row.speaker }
            } else {
                let line = TranscriptLineRecord(
                    index: row.index,
                    speaker: row.speaker,
                    text: row.text,
                    startSeconds: row.startSeconds,
                    capturedAt: row.capturedAt
                )
                line.meeting = meeting
                context.insert(line)
                meeting.lines.append(line)
            }
        }
        meeting.lastChunk = max(meeting.lastChunk, updates.chunkCount)

        // Reconcile the suggestion board against the FULL active set the workflow
        // returned: drop cards no longer active (applied/irrelevant), update the
        // ones that remain, and insert new ones. Only reconcile while live so a
        // finished note keeps its final active set.
        if !meeting.state.isTerminal {
            let incomingIds = Set(updates.suggestions.map(\.id))
            // Remove cards that are no longer on the board (match by stable id;
            // ignore legacy records with an empty id so we don't wipe old notes).
            for rec in meeting.suggestions where !rec.suggestionId.isEmpty && !incomingIds.contains(rec.suggestionId) {
                meeting.suggestions.removeAll { $0 === rec }
                context.delete(rec)
            }
            // Upsert the current board.
            for s in updates.suggestions {
                // Don't resurrect a locally-dismissed card before the workflow
                // catches up and stops returning it.
                if !s.id.isEmpty, dismissedSuggestionIds.contains(s.id) { continue }
                if let existing = meeting.suggestions.first(where: { $0.suggestionId == s.id && !s.id.isEmpty }) {
                    existing.kind = s.kind
                    existing.title = s.title
                    existing.detail = s.detail
                    existing.priority = s.priority
                    existing.atChunk = s.atChunk
                } else {
                    let rec = SuggestionRecord(
                        suggestionId: s.id,
                        atChunk: s.atChunk,
                        kind: s.kind,
                        title: s.title,
                        detail: s.detail,
                        priority: s.priority
                    )
                    rec.meeting = meeting
                    context.insert(rec)
                    meeting.suggestions.append(rec)
                }
            }
        }

        if !updates.roster.isEmpty { meeting.roster = updates.roster }

        if let summary = updates.summary {
            meeting.summaryText = summary.summary
            meeting.attendees = summary.attendees
            meeting.keyPoints = summary.keyPoints
            meeting.actionItems = summary.actionItems
            meeting.nextSteps = summary.nextSteps
            meeting.feedbackText = summary.feedback
            meeting.score = summary.score
        }

        var newState = MeetingState.fromWorkflow(updates.state)
        // Once a stop has been requested (locally or server-side), never fall back to
        // "recording" — stay in "summarizing" until the workflow is actually done.
        if (meeting.stopRequested || updates.stopRequested || updates.abortRequested),
           newState == .recording {
            newState = .summarizing
        }
        if newState == .stopped && meeting.hasSummary { newState = .completed }
        meeting.state = newState

        try? context.save()
    }
}
