import Foundation

/// All tuning knobs for the in-process Swift worker. Populated from `Settings`
/// (the app is the source of truth) before the worker starts.
///
/// The workflow reads these via `WorkerConfig.current`. They are set once before
/// the worker starts and are constant for its lifetime, so they are replay-safe
/// within a worker process.
struct WorkerConfig: Sendable {
    // Role / LLM
    var role: String?                 // "ae" | "sa" | "bdr" | nil
    var llmProvider: String           // "openai" | "anthropic"
    var llmModel: String?             // nil -> provider default
    var openaiApiKey: String?
    var anthropicApiKey: String?

    // Analysis cadence / board
    var aiAssistanceEnabled: Bool     // default for new meetings (per-meeting in MeetingInput)
    var analyzeEveryNChunks: Int
    var analysisWarmupMinutes: Double
    var maxActiveSuggestions: Int

    // Capture / transcription
    var chunkSeconds: Double
    var silenceTimeoutSeconds: Double
    var silencePeakThreshold: Float
    var silenceRmsThreshold: Float
    var audioSampleRate: Int
    var whisperModel: String

    // Output
    var outputDir: String
    var streamDrainSeconds: Double

    static let defaultOpenAIModel = "gpt-4o"
    static let defaultAnthropicModel = "claude-sonnet-5-5"

    init(
        role: String? = nil,
        llmProvider: String = "openai",
        llmModel: String? = nil,
        openaiApiKey: String? = nil,
        anthropicApiKey: String? = nil,
        aiAssistanceEnabled: Bool = true,
        analyzeEveryNChunks: Int = 3,
        analysisWarmupMinutes: Double = 5.0,
        maxActiveSuggestions: Int = 5,
        chunkSeconds: Double = 20.0,
        silenceTimeoutSeconds: Double = 300.0,
        silencePeakThreshold: Float = 0.02,
        silenceRmsThreshold: Float = 0.005,
        audioSampleRate: Int = 16_000,
        whisperModel: String = "base",
        outputDir: String = "out",
        streamDrainSeconds: Double = 0.0
    ) {
        self.role = role
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.openaiApiKey = openaiApiKey
        self.anthropicApiKey = anthropicApiKey
        self.aiAssistanceEnabled = aiAssistanceEnabled
        self.analyzeEveryNChunks = analyzeEveryNChunks
        self.analysisWarmupMinutes = analysisWarmupMinutes
        self.maxActiveSuggestions = maxActiveSuggestions
        self.chunkSeconds = chunkSeconds
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.silencePeakThreshold = silencePeakThreshold
        self.silenceRmsThreshold = silenceRmsThreshold
        self.audioSampleRate = audioSampleRate
        self.whisperModel = whisperModel
        self.outputDir = outputDir
        self.streamDrainSeconds = streamDrainSeconds
    }

    /// The effective model name for a provider, matching Python `config.llm_model`.
    func model(for provider: String) -> String {
        if let m = llmModel, !m.isEmpty { return m }
        return provider == "anthropic" ? Self.defaultAnthropicModel : Self.defaultOpenAIModel
    }

    /// Resolved absolute output directory for the Google Doc stub. Defaults under
    /// Application Support so the sandboxed/unsandboxed app can always write it.
    var resolvedOutputDir: String {
        if (outputDir as NSString).isAbsolutePath { return outputDir }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ZiggyNotes").appendingPathComponent(outputDir).path
    }

    /// Process-global config read by the workflow and activities. Set once before
    /// the worker starts (see `WorkerRuntime`).
    nonisolated(unsafe) static var current = WorkerConfig()
}
