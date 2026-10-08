import Foundation
import Temporal

/// Durable orchestrator for one meeting, minus Workflow Streams (the macOS app
/// polls `get_updates`), plus native capture.
///
/// Lifecycle:
///   1. Starts the long-running `capture_audio` activity (mic + system output).
///   2. Receives transcribed chunks via the `add_transcript_chunk` signal and
///      appends them to its transcript buffer.
///   3. Every `analyzeEveryNChunks` new chunks (after a warmup), runs
///      `identify_speakers` then `analyze_conversation`, maintaining a ranked,
///      capped suggestion board.
///   4. Ends on a `stop_recording` signal or when capture stops itself after the
///      silence timeout.
///   5. Summarizes, writes the (stubbed) Google Doc, and returns a MeetingResult.
@Workflow(name: "MeetingWorkflow")
struct MeetingWorkflow {
    // MARK: - State

    var chunks: [TranscriptChunk] = []
    var stopRequested = false
    var abortRequested = false
    var lastAnalyzedCount = 0
    var activeSuggestions: [ZiggyObservation] = []
    var nextSuggestionSeq = 0
    var labels: [Int: String] = [:]
    var roster: [String] = []
    var summary: MeetingSummary?
    var state = "starting"

    // Capture outcome, recorded by the capture child task via `mutateState`.
    var captureResult: CaptureResult?
    var captureFailed = false
    var captureDone = false

    private static let priorityRank = ["high": 0, "medium": 1, "low": 2]

    // MARK: - Signals

    /// Append a transcribed chunk (from the capture activity). Seeds the resolved
    /// label with the source-based default; `identify_speakers` may upgrade it.
    @WorkflowSignal(name: "add_transcript_chunk")
    mutating func addTranscriptChunk(input: TranscriptChunk) {
        chunks.append(input)
        let label = input.speaker.isEmpty ? defaultLabel(input.source) : input.speaker
        if labels[input.index] == nil { labels[input.index] = label }
    }

    /// First stop finalizes (summarize + exit); a second stop escalates to abort
    /// (cancel in-flight finalize work and exit now).
    @WorkflowSignal(name: "stop_recording")
    mutating func stopRecording(input: Void) {
        if stopRequested { abortRequested = true }
        stopRequested = true
    }

    /// Force-exit now: cancel in-flight work and finish without waiting.
    @WorkflowSignal(name: "abort")
    mutating func abort(input: Void) {
        stopRequested = true
        abortRequested = true
    }

    // MARK: - Queries

    struct StatusResult: Codable, Sendable {
        var state: String
        var chunkCount: Int
        var stopRequested: Bool
        var abortRequested: Bool
        var hasSummary: Bool
        var roster: [String]
        enum CodingKeys: String, CodingKey {
            case state
            case chunkCount = "chunk_count"
            case stopRequested = "stop_requested"
            case abortRequested = "abort_requested"
            case hasSummary = "has_summary"
            case roster
        }
    }

    @WorkflowQuery(name: "status")
    func statusQuery(input: Void) -> StatusResult {
        StatusResult(
            state: state, chunkCount: chunks.count, stopRequested: stopRequested,
            abortRequested: abortRequested, hasSummary: summary != nil, roster: roster
        )
    }

    @WorkflowQuery(name: "get_summary")
    func getSummary(input: Void) -> MeetingSummary? { summary }

    @WorkflowQuery(name: "get_updates")
    func getUpdates(input: UpdatesCursor) -> MeetingUpdates {
        let sinceChunk = input.sinceChunk
        let rows = chunks.filter { $0.index >= sinceChunk }.map { c in
            TranscriptRow(index: c.index, speaker: labelFor(c), text: c.text,
                          startSeconds: c.startSeconds, endSeconds: c.endSeconds)
        }
        let suggRows = activeSuggestions.map { o in
            SuggestionRow(id: o.id, atChunk: 0, kind: o.kind, title: o.title,
                          detail: o.detail, priority: o.priority)
        }
        var labelStrings: [String: String] = [:]
        for (k, v) in labels { labelStrings[String(k)] = v }
        return MeetingUpdates(
            state: state, stopRequested: stopRequested, abortRequested: abortRequested,
            chunkCount: chunks.count, suggestionCount: activeSuggestions.count,
            transcript: rows, suggestions: suggRows, labels: labelStrings,
            roster: roster, summary: summary
        )
    }

    // MARK: - Run

    mutating func run(context: WorkflowContext<Self>, input: MeetingInput) async throws -> MeetingResult {
        state = "recording"
        let cfg = WorkerConfig.current

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Long-running capture. Unlimited retries so a worker restart/crash
            // resumes capture rather than ending the meeting.
            group.addTask {
                let opts = ActivityOptions(
                    startToCloseTimeout: .seconds(8 * 60 * 60),
                    cancellationType: .tryCancel,
                    heartbeatTimeout: .seconds(30),
                    retryPolicy: RetryPolicy(
                        initialInterval: .seconds(1), backoffCoefficient: 2.0,
                        maximumInterval: .seconds(30), maximumAttempts: 0
                    )
                )
                do {
                    let result = try await context.executeActivity(
                        ZiggyActivities.Activities.CaptureAudio.self,
                        options: opts,
                        input: CaptureInput(meetingId: input.meetingId, language: input.language)
                    )
                    context.mutateState { $0.captureResult = result; $0.captureDone = true }
                } catch is CancellationError {
                    context.mutateState { $0.captureDone = true }   // expected on stop
                } catch {
                    context.mutateState { $0.captureFailed = true; $0.captureDone = true }
                }
            }

            // Orchestration loop (runs in the group body: may mutate self).
            try await orchestrate(context: context, input: input, cfg: cfg)

            // Stop capture if it's still running.
            group.cancelAll()
        }

        // Determine stop reason from the capture outcome.
        let (capResult, capFailed) = context.mutateState { ($0.captureResult, $0.captureFailed) }
        var stopReason = stopRequested ? "stopped" : "capture_ended"
        if let r = capResult { stopReason = r.stopReason }
        else if capFailed { stopReason = "capture_error" }

        // Trailing analysis for chunks that didn't hit the cadence -- skipped on
        // stop (user wants to finalize) and when AI assistance is off.
        if input.aiAssistance && !stopRequested && chunks.count > lastAnalyzedCount
            && elapsedSeconds() >= cfg.analysisWarmupMinutes * 60 {
            await runAnalysis(context: context, input: input, cfg: cfg)
        }

        // Final speaker attribution so the summary/transcript use real names.
        await runIdentify(
            context: context, input: input,
            retryPolicy: Self.summaryRetry, startToClose: Self.summaryStartToClose,
            scheduleToClose: Self.summaryScheduleToClose, watchAbort: true
        )

        // --- summarize --------------------------------------------------------
        state = "summarizing"
        let transcript = renderTranscript()
        let summaryOpts = ActivityOptions(
            startToCloseTimeout: Self.summaryStartToClose,
            scheduleToCloseTimeout: Self.summaryScheduleToClose,
            cancellationType: .tryCancel, retryPolicy: Self.summaryRetry
        )
        let summaryInput = SummaryInput(
            title: input.title, transcript: transcript, callContext: input.callContext,
            guidelines: input.summaryGuidelines, structure: input.summaryStructure
        )
        let summaryResult = await finishOrAbort(context: context) {
            try await context.executeActivity(
                ZiggyActivities.Activities.SummarizeMeeting.self, options: summaryOpts, input: summaryInput
            )
        }
        let finalSummary: MeetingSummary
        switch summaryResult {
        case .value(let s): finalSummary = s
        case .aborted: finalSummary = MeetingSummary(summary: "Summary aborted by user; full transcript is preserved.")
        case .failed: finalSummary = MeetingSummary(summary: "Summary unavailable (LLM error); full transcript is preserved.")
        }
        summary = finalSummary

        // --- Google Doc (stubbed) --------------------------------------------
        var googleDoc: GoogleDocRef
        if abortRequested {
            googleDoc = GoogleDocRef(docId: "aborted", url: "", localPath: nil)
        } else {
            let gdocOpts = ActivityOptions(
                startToCloseTimeout: .seconds(20), scheduleToCloseTimeout: .seconds(30),
                cancellationType: .tryCancel, retryPolicy: RetryPolicy(maximumAttempts: 3)
            )
            let gdocInput = GoogleDocInput(
                meetingId: input.meetingId, title: input.title, summary: finalSummary, transcript: transcript
            )
            let gdocResult = await finishOrAbort(context: context) {
                try await context.executeActivity(
                    ZiggyActivities.Activities.CreateGoogleDoc.self, options: gdocOpts, input: gdocInput
                )
            }
            switch gdocResult {
            case .value(let d): googleDoc = d
            default: googleDoc = GoogleDocRef(docId: "unavailable", url: "", localPath: nil)
            }
        }

        state = "completed"
        if cfg.streamDrainSeconds > 0 {
            try await context.sleep(for: .seconds(cfg.streamDrainSeconds))
        }

        return MeetingResult(
            meetingId: input.meetingId, title: input.title, chunkCount: chunks.count,
            stopReason: stopReason, transcript: transcript, summary: finalSummary,
            googleDoc: googleDoc, roster: roster
        )
    }

    // MARK: - Orchestration loop

    private mutating func orchestrate(
        context: WorkflowContext<Self>, input: MeetingInput, cfg: WorkerConfig
    ) async throws {
        while true {
            if !input.aiAssistance {
                // Transcript-only: still receive chunks via the signal handler;
                // run no analysis. Wait until the user stops or capture ends.
                try await context.condition { $0.stopRequested || $0.captureDone }
                break
            }
            let threshold = cfg.analyzeEveryNChunks
            try await context.condition {
                $0.stopRequested || $0.captureDone
                    || ($0.chunks.count - $0.lastAnalyzedCount) >= threshold
            }
            if stopRequested || captureDone { break }
            // Warmup: no live guidance until enough elapsed call time has passed.
            if elapsedSeconds() < cfg.analysisWarmupMinutes * 60 {
                lastAnalyzedCount = chunks.count
                continue
            }
            await runIdentify(
                context: context, input: input,
                retryPolicy: Self.llmRetry, startToClose: .seconds(60),
                scheduleToClose: nil, watchAbort: false
            )
            await runAnalysis(context: context, input: input, cfg: cfg)
        }
    }

    // MARK: - Analysis / identity

    private mutating func runAnalysis(
        context: WorkflowContext<Self>, input: MeetingInput, cfg: WorkerConfig
    ) async {
        lastAnalyzedCount = chunks.count
        let transcript = renderTranscript()
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        state = "analyzing"
        let opts = ActivityOptions(
            startToCloseTimeout: .seconds(90), cancellationType: .tryCancel, retryPolicy: Self.llmRetry
        )
        let analysisInput = AnalysisInput(
            title: input.title, transcript: transcript, callContext: input.callContext,
            currentSuggestions: activeSuggestions, maxSuggestions: cfg.maxActiveSuggestions
        )
        let outcome = await raceAgainstStop(context: context) {
            try await context.executeActivity(
                ZiggyActivities.Activities.AnalyzeConversation.self, options: opts, input: analysisInput
            )
        }
        if case .value(let result) = outcome {
            applySuggestions(result.observations, cfg: cfg)
        }
        state = "recording"
    }

    private mutating func runIdentify(
        context: WorkflowContext<Self>, input: MeetingInput,
        retryPolicy: RetryPolicy, startToClose: Duration,
        scheduleToClose: Duration?, watchAbort: Bool
    ) async {
        let transcript = renderForIdentity()
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        let opts = ActivityOptions(
            startToCloseTimeout: startToClose, scheduleToCloseTimeout: scheduleToClose,
            cancellationType: .tryCancel, retryPolicy: retryPolicy
        )
        let identityInput = IdentityInput(
            title: input.title, transcript: transcript,
            callContext: input.callContext, repName: input.repName
        )
        let run: @Sendable () async throws -> IdentityResult = {
            try await context.executeActivity(
                ZiggyActivities.Activities.IdentifySpeakers.self, options: opts, input: identityInput
            )
        }
        let outcome = watchAbort
            ? await finishOrAbort(context: context, run)
            : await raceAgainstStop(context: context, run)
        if case .value(let result) = outcome {
            applyIdentity(result)
        }
    }

    // MARK: - Suggestion board

    private mutating func newSid() -> String {
        let sid = "s\(nextSuggestionSeq)"
        nextSuggestionSeq += 1
        return sid
    }

    private mutating func applySuggestions(_ desired: [ZiggyObservation], cfg: WorkerConfig) {
        let existingIds = Set(activeSuggestions.map(\.id).filter { !$0.isEmpty })
        var merged: [ZiggyObservation] = []
        for obs in desired {
            let oid = (!obs.id.isEmpty && existingIds.contains(obs.id)) ? obs.id : newSid()
            merged.append(ZiggyObservation(id: oid, kind: obs.kind, title: obs.title,
                                      detail: obs.detail, priority: obs.priority))
        }
        // Rank high->medium->low, keeping model order within a priority as a
        // recency tiebreak, then enforce the cap.
        let ranked = merged.enumerated().sorted { a, b in
            let ra = Self.priorityRank[a.element.priority] ?? 1
            let rb = Self.priorityRank[b.element.priority] ?? 1
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        activeSuggestions = ranked.prefix(cfg.maxActiveSuggestions).map(\.element)
    }

    private mutating func applyIdentity(_ result: IdentityResult) {
        let valid = Set(chunks.map(\.index))
        for a in result.assignments where valid.contains(a.index) && !a.label.isEmpty {
            labels[a.index] = a.label
        }
        if !result.roster.isEmpty && result.roster != roster {
            roster = result.roster
        }
    }

    // MARK: - Transcript rendering

    private func labelFor(_ chunk: TranscriptChunk) -> String {
        if let l = labels[chunk.index], !l.isEmpty { return l }
        return chunk.speaker.isEmpty ? defaultLabel(chunk.source) : chunk.speaker
    }

    private func elapsedSeconds() -> Double {
        chunks.map(\.endSeconds).max() ?? 0
    }

    private func renderTranscript() -> String {
        chunks.map { c in
            let ts = Int(c.startSeconds)
            return String(format: "[%02d:%02d] %@: %@", ts / 60, ts % 60, labelFor(c), c.text)
        }.joined(separator: "\n")
    }

    private func renderForIdentity() -> String {
        chunks.map { c in
            let ts = Int(c.startSeconds)
            return String(format: "[%d] (%@) [%02d:%02d] %@", c.index, c.source, ts / 60, ts % 60, c.text)
        }.joined(separator: "\n")
    }

    // MARK: - Activity racing helpers

    enum ActivityOutcome<T: Sendable>: Sendable { case value(T); case aborted; case failed }

    /// Run a cancellable activity, racing it against the stop flag. If stop wins,
    /// cancel the activity and return `.aborted`.
    private func raceAgainstStop<Output: Sendable>(
        context: WorkflowContext<Self>, _ body: @escaping @Sendable () async throws -> Output
    ) async -> ActivityOutcome<Output> {
        await race(context: context, flag: { $0.stopRequested }, body)
    }

    /// Run a finalize activity, racing it against the abort flag.
    private func finishOrAbort<Output: Sendable>(
        context: WorkflowContext<Self>, _ body: @escaping @Sendable () async throws -> Output
    ) async -> ActivityOutcome<Output> {
        await race(context: context, flag: { $0.abortRequested }, body)
    }

    private func race<Output: Sendable>(
        context: WorkflowContext<Self>,
        flag: @escaping @Sendable (MeetingWorkflow) -> Bool,
        _ body: @escaping @Sendable () async throws -> Output
    ) async -> ActivityOutcome<Output> {
        await withTaskGroup(of: RaceStep<Output>.self) { group in
            group.addTask {
                do { return .done(try await body()) } catch { return .failed }
            }
            group.addTask {
                try? await context.condition { flag($0) }
                return .flagged
            }
            defer { group.cancelAll() }
            for await step in group {
                switch step {
                case .done(let o): return .value(o)
                case .failed: return .failed
                case .flagged: return .aborted
                }
            }
            return .failed
        }
    }

    // MARK: - Retry policies

    static let llmRetry = RetryPolicy(
        initialInterval: .seconds(1), backoffCoefficient: 2.0,
        maximumInterval: .seconds(30), maximumAttempts: 0
    )
    static let summaryRetry = RetryPolicy(
        initialInterval: .seconds(1), backoffCoefficient: 2.0,
        maximumInterval: .seconds(5), maximumAttempts: 3
    )
    static let summaryStartToClose: Duration = .seconds(30)
    static let summaryScheduleToClose: Duration = .seconds(40)
}

/// Result of one branch of the activity-vs-flag race (file-scope so it can be
/// generic over the activity output).
private enum RaceStep<Output: Sendable>: Sendable {
    case done(Output)
    case failed
    case flagged
}
