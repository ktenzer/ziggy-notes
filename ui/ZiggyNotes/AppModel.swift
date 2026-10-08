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
        settings.hydrateFromEnvIfNeeded(projectDir: worker.projectDir)
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

        phase = .startingWorker
        do {
            try await worker.start(environment: settings.workerEnvironment())
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

    /// Applies updated settings: writes `.env`, restarts the worker, and reconnects.
    func reload() async {
        pollTask?.cancel()
        pollTask = nil
        worker.stop()
        await client.shutdown()
        try? settings.writeEnv(projectDir: worker.projectDir)
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
                    startSeconds: row.startSeconds
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
