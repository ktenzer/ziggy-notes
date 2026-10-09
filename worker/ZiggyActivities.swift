import Foundation
import Temporal

/// All Ziggy activities, in-process (analysis, identity, summary, gdoc, capture).
///
/// Holds the `WorkerConfig` (role/LLM/tuning) and the shared `TemporalClient` so
/// the long-running `capture_audio` activity can signal the workflow with
/// `add_transcript_chunk` -- the Swift SDK does not expose a client inside an
/// activity (Python used `activity.client()`), so we inject it here.
@ActivityContainer
struct ZiggyActivities {
    let config: WorkerConfig
    let client: TemporalClient

    private var llm: LLMClient { LLMClient(config: config) }

    // MARK: - JSON shape hints (replace Python/pydantic strict schemas)

    private static let analysisHint = """
    {"observations": [{"id": "", "kind": "bring_up|explain_feature|address_objection|answer_question|risk|next_step", "title": "string", "detail": "string", "priority": "high|medium|low"}]}
    """
    private static let summaryHint = """
    {"summary": "string", "attendees": ["string"], "key_points": ["string"], "action_items": ["string"], "next_steps": ["string"], "feedback": "string", "score": 0}
    """
    private static let answerHint = """
    {"answer": "string", "done": true, "notes": "string"}
    """

    // MARK: - LLM activities

    /// Active-listening analysis. Mirrors `activities/analysis.py`.
    @Activity(name: "analyze_conversation")
    func analyzeConversation(input: AnalysisInput) async throws -> AnalysisResult {
        let userPrompt = Prompts.buildAnalysisUserPrompt(
            title: input.title,
            transcript: input.transcript,
            callContext: input.callContext,
            currentSuggestions: input.currentSuggestions,
            dismissedSuggestions: input.dismissedSuggestions,
            maxSuggestions: input.maxSuggestions
        )
        let systemPrompt = Prompts.analysisSystemPrompt(RoleGuidance.load(config.role))
        let result: AnalysisResult = try await llm.structuredCompletion(
            system: systemPrompt, user: userPrompt, jsonHint: Self.analysisHint, as: AnalysisResult.self
        )
        ActivityExecutionContext.current?.logger.info(
            "analysis returned \(result.observations.count) suggestion(s) for a board of \(input.currentSuggestions.count)"
        )
        return result
    }

    /// Final meeting summary. Mirrors `activities/summary.py`. Also identifies the
    /// call attendees as part of the same LLM call (there is no separate
    /// `identify_speakers` pass). The app user is named from the typed rep name
    /// when provided, else the local macOS account's full name.
    @Activity(name: "summarize_meeting")
    func summarizeMeeting(input: SummaryInput) async throws -> MeetingSummary {
        let userName = (input.repName?.isEmpty == false) ? input.repName : NSFullUserName()
        let userPrompt = Prompts.buildSummaryUserPrompt(
            title: input.title,
            transcript: input.transcript,
            callContext: input.callContext,
            guidelines: input.guidelines,
            structure: input.structure,
            userName: userName
        )
        let systemPrompt = Prompts.summarySystemPromptWithRole(RoleGuidance.load(config.role))
        let summary: MeetingSummary = try await llm.structuredCompletion(
            system: systemPrompt, user: userPrompt, jsonHint: Self.summaryHint, as: MeetingSummary.self
        )
        ActivityExecutionContext.current?.logger.info(
            "summary produced: \(summary.attendees.count) attendee(s), \(summary.keyPoints.count) key point(s), \(summary.actionItems.count) action item(s), \(summary.nextSteps.count) next step(s), score=\(summary.score)"
        )
        return summary
    }

    /// Answers a user's "ask anything" question about the meeting, grounded in the
    /// transcript + current guidance. One step of the ask workflow's agent loop.
    @Activity(name: "answer_question")
    func answerQuestion(input: AnswerInput) async throws -> AnswerResult {
        let userPrompt = Prompts.buildAskUserPrompt(
            title: input.title,
            question: input.question,
            transcript: input.transcript,
            guidance: input.guidance,
            priorNotes: input.priorNotes
        )
        let systemPrompt = Prompts.askSystemPrompt(RoleGuidance.load(config.role))
        // Ask uses raw completion + lenient parse: an "ask anything" answer is
        // free text, so if the model replies in prose/markdown instead of the
        // requested JSON (it occasionally does for "summarize…"-style questions),
        // we use that text as the answer rather than hard-failing the workflow.
        let raw = try await llm.rawCompletion(
            system: systemPrompt, user: userPrompt, jsonHint: Self.answerHint
        )
        let result = LLMClient.tolerantDecode(raw, as: AnswerResult.self)
            ?? AnswerResult(answer: raw.trimmingCharacters(in: .whitespacesAndNewlines), done: true, notes: "")
        ActivityExecutionContext.current?.logger.info(
            "answer_question: done=\(result.done), \(result.answer.count) char answer"
        )
        return result
    }

    /// Writes the summary to a local Markdown file (Google Doc stub). Mirrors
    /// `activities/gdoc.py`.
    @Activity(name: "create_google_doc")
    func createGoogleDoc(input: GoogleDocInput) async throws -> GoogleDocRef {
        let dir = config.resolvedOutputDir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(input.meetingId).md")
        let content = Self.renderMarkdown(title: input.title, summary: input.summary, transcript: input.transcript)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        ActivityExecutionContext.current?.logger.info("wrote meeting doc (Google Doc stub) to \(path)")
        return GoogleDocRef(docId: "stub-\(input.meetingId)", url: "file://\(path)", localPath: path)
    }

    private static func renderMarkdown(title: String, summary: MeetingSummary, transcript: String) -> String {
        func bullets(_ items: [String]) -> String {
            items.isEmpty ? "_None_" : items.map { "- \($0)" }.joined(separator: "\n")
        }
        return """
        # \(title)

        ## Summary

        \(summary.summary.isEmpty ? "_No summary produced._" : summary.summary)

        ## Key Points

        \(bullets(summary.keyPoints))

        ## Action Items

        \(bullets(summary.actionItems))

        ## Next Steps

        \(bullets(summary.nextSteps))

        ---

        ## Full Transcript

        \(transcript.isEmpty ? "_No transcript captured._" : transcript)
        """
    }

    // MARK: - Capture activity

    /// Long-running native audio capture + transcription. Mirrors
    /// `activities/capture.py`, but uses AVAudioEngine (mic) + ScreenCaptureKit
    /// (system audio) so it works out of the box with no loopback driver.
    @Activity(name: "capture_audio")
    func captureAudio(input: CaptureInput) async throws -> CaptureResult {
        let cfg = WorkerConfig.current
        let logger = ActivityExecutionContext.current?.logger ?? ZiggyLog.shared
        guard let wfId = ActivityExecutionContext.current?.info.workflowID else {
            throw ApplicationError(message: "capture_audio has no workflow context", type: "NoContext", isNonRetryable: true)
        }
        let handle = client.untypedWorkflowHandle(id: wfId)

        let capture = AudioCapture(sampleRate: Double(cfg.audioSampleRate), logger: logger)
        try await capture.start()
        if !capture.micCaptured && !capture.systemCaptured {
            await capture.stop()
            throw ApplicationError(
                message: "No audio inputs could be opened (mic and system both failed). Check Microphone and Screen Recording permissions in System Settings > Privacy.",
                type: "NoAudioDevice", isNonRetryable: true
            )
        }
        logger.info("capture started: mic=\(capture.micCaptured) system=\(capture.systemCaptured) sample_rate=\(cfg.audioSampleRate)")

        let transcriber = Transcriber(modelName: cfg.whisperModel, logger: logger)
        try await transcriber.load()

        var chunkIndex = 0
        var totalSeconds = 0.0
        var silenceElapsed = 0.0
        var stopReason = "unknown"
        // Last accepted transcription per source, to drop consecutive duplicates
        // (a classic Whisper silence-hallucination artifact).
        var lastText: [String: String] = [:]

        do {
            while true {
                // Sleep one chunk in small, cancellable steps; heartbeat so the
                // workflow can cancel us and the server knows we're alive.
                var waited = 0.0
                let step = 0.5
                while waited < cfg.chunkSeconds {
                    try await Task.sleep(for: .seconds(min(step, cfg.chunkSeconds - waited)))
                    waited += step
                    ActivityExecutionContext.current?.heartbeat(details: chunkIndex)
                }

                let windowStart = totalSeconds
                let windowEnd = totalSeconds + cfg.chunkSeconds
                totalSeconds = windowEnd

                var anySpeech = false
                for source in [ZiggySource.mic, ZiggySource.output] {
                    guard capture.isActive(source) else { continue }
                    let audio = capture.drain(source)
                    let rms = Self.rms(audio)
                    let peak = audio.map { abs($0) }.max() ?? 0
                    let hasAudio = peak >= cfg.silencePeakThreshold || rms >= cfg.silenceRmsThreshold
                    let secs = cfg.audioSampleRate > 0 ? Double(audio.count) / Double(cfg.audioSampleRate) : 0
                    logger.info("chunk \(chunkIndex) [\(source)]: samples=\(audio.count) (\(String(format: "%.1f", secs))s) rms=\(String(format: "%.4f", rms)) peak=\(String(format: "%.4f", peak)) -> \(hasAudio ? "audio" : "silence")")
                    if audio.isEmpty {
                        logger.warning("[\(source)] no audio frames captured this chunk -- device may not be delivering input")
                        continue
                    }
                    if !hasAudio { continue }
                    let text = try await transcriber.transcribe(audio, language: input.language)
                    if text.isEmpty {
                        logger.info("[\(source)] audio present but transcriber returned no text (VAD filtered?)")
                        continue
                    }
                    // Drop trivial output (punctuation/empty after stripping).
                    let alnum = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                    if alnum.count < 2 {
                        logger.info("[\(source)] dropping trivial transcription: \(text)")
                        continue
                    }
                    // Drop Whisper non-speech hallucinations on silence/noise:
                    // lines that are mostly bracketed sound-event markers
                    // ("*spoiled*", "(applause)", "[music]") or a single token
                    // repeated many times. These are never real speech.
                    if Self.looksLikeHallucination(text) {
                        logger.info("[\(source)] dropping hallucinated non-speech line: \(text)")
                        continue
                    }
                    // Drop a verbatim repeat of the previous accepted line from the
                    // same source — real back-to-back identical sentences don't happen,
                    // but hallucinated phrases do.
                    if let prev = lastText[source], prev.caseInsensitiveCompare(text) == .orderedSame {
                        logger.info("[\(source)] dropping duplicate of previous chunk: \(text)")
                        continue
                    }
                    lastText[source] = text
                    anySpeech = true
                    // Actual time of day this window finished capturing (epoch
                    // seconds); the UI renders it in the user's timezone.
                    let capturedAt = Date().timeIntervalSince1970
                    let chunk = TranscriptChunk(
                        index: chunkIndex, source: source, speaker: defaultLabel(source),
                        text: text, startSeconds: windowStart, endSeconds: windowEnd,
                        capturedAt: capturedAt
                    )
                    try await handle.signal(signalName: "add_transcript_chunk", input: chunk)
                    logger.info("[\(source)] signaled chunk \(chunkIndex): \(text)")
                    chunkIndex += 1
                }

                if anySpeech {
                    silenceElapsed = 0
                } else {
                    silenceElapsed += cfg.chunkSeconds
                    if cfg.silenceTimeoutSeconds > 0 && silenceElapsed >= cfg.silenceTimeoutSeconds {
                        stopReason = "silence_timeout"
                        logger.info("stopping after \(Int(silenceElapsed))s of continuous silence")
                        break
                    }
                }
            }
        } catch is CancellationError {
            // Worker shutdown != end of meeting: fail the attempt so capture
            // resumes on a healthy worker. A workflow stop finalizes normally.
            if case .workerShutdown? = ActivityExecutionContext.current?.cancellationReason {
                await capture.stop()
                logger.warning("capture cancelled by WORKER SHUTDOWN; failing attempt so it resumes")
                throw ApplicationError(message: "capture interrupted by worker shutdown; resuming", type: "WorkerShutdown")
            }
            stopReason = "cancelled"
            logger.info("capture cancelled by workflow (stop_recording)")
        }

        await capture.stop()
        return CaptureResult(
            chunkCount: chunkIndex, durationSeconds: totalSeconds, stopReason: stopReason,
            micCaptured: capture.micCaptured, systemCaptured: capture.systemCaptured
        )
    }

    /// Heuristic detector for Whisper non-speech hallucinations (emitted on
    /// silence/noise): text that is mostly bracketed sound-event markers like
    /// `*word*`, `(word)`, `[word]`, or the same token repeated over and over.
    static func looksLikeHallucination(_ text: String) -> Bool {
        let tokens = text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else { return true }

        func isMarker(_ t: String) -> Bool {
            (t.hasPrefix("*") && t.hasSuffix("*"))
                || (t.hasPrefix("(") && t.hasSuffix(")"))
                || (t.hasPrefix("[") && t.hasSuffix("]"))
        }
        // Mostly bracketed sound-event markers -> not real speech.
        let markerCount = tokens.filter(isMarker).count
        if Double(markerCount) / Double(tokens.count) >= 0.5 { return true }

        // Extreme repetition: several tokens but very few distinct ones.
        if tokens.count >= 6 {
            let distinct = Set(tokens.map { $0.lowercased() }).count
            if Double(distinct) / Double(tokens.count) <= 0.34 { return true }
        }
        return false
    }

    private static func rms(_ audio: [Float]) -> Float {
        guard !audio.isEmpty else { return 0 }
        var sum: Float = 0
        for s in audio { sum += s * s }
        return (sum / Float(audio.count)).squareRoot()
    }
}
