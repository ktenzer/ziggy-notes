import Foundation
import Observation

/// User-editable configuration, persisted to `UserDefaults` and written through to
/// the project's `.env` so the Python worker picks it up on (re)start. Values are
/// also injected directly into the worker's process environment, which takes
/// precedence over any stale shell variables (`load_dotenv` does not override).
@MainActor
@Observable
final class Settings {
    enum Provider: String, CaseIterable, Identifiable {
        case openai, anthropic
        var id: String { rawValue }
        var label: String { self == .openai ? "OpenAI" : "Anthropic" }
    }

    /// The user's sales role, which tailors live guidance and the summary
    /// (written through to the worker as `USER_ROLE`). Required — there is no
    /// default; the app prompts for it before a note can be started.
    enum Role: String, CaseIterable, Identifiable {
        case ae, sa, bdr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ae:  return "Account Executive"
            case .sa:  return "Solution Architect"
            case .bdr: return "Business Development Representative"
            }
        }
    }

    // Role (required)
    var role: Role? = nil

    // LLM
    var provider: Provider = .openai
    var openAIKey: String = ""
    var anthropicKey: String = ""
    var llmModel: String = ""

    // AI assistance: when on (default), surface live active-listening guidance
    // during the call. When off, only transcribe + summarize (no live suggestions).
    var aiAssistance: Bool = true

    // Temporal
    var useTemporalCloud: Bool = false
    var temporalAddress: String = "localhost:7233"
    var temporalNamespace: String = "default"
    var temporalApiKey: String = ""

    // App configuration
    var chunkSeconds: Double = 20
    var analyzeEveryNChunks: Int = 3
    // Minutes of elapsed call time before any live guidance is surfaced.
    var warmupMinutes: Double = 5
    // Max number of live suggestions shown at once.
    var maxActiveSuggestions: Int = 5

    // Output
    var outputDir: String = ""

    // Advanced capture / transcription (sensible defaults; rarely changed)
    var whisperModel: String = "base"
    var audioSampleRate: Int = 16_000
    var silenceTimeoutSeconds: Double = 300
    var silencePeakThreshold: Double = 0.02
    var silenceRmsThreshold: Double = 0.005

    /// WhisperKit model sizes offered in the UI. Larger = more accurate + slower,
    /// and triggers a one-time download unless bundled offline.
    static let whisperModels = ["tiny", "base", "small", "medium", "large-v3"]

    private let d = UserDefaults.standard

    init() { load() }

    // MARK: - Validation

    var apiKeyForProvider: String {
        provider == .openai ? openAIKey : anthropicKey
    }

    var isValid: Bool {
        guard role != nil else { return false }
        guard !apiKeyForProvider.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if useTemporalCloud {
            if temporalAddress.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if temporalNamespace.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if temporalApiKey.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }

    // MARK: - Persistence (UserDefaults)

    func load() {
        role = (d.string(forKey: "userRole")).flatMap(Role.init(rawValue:))
        provider = Provider(rawValue: d.string(forKey: "llmProvider") ?? "openai") ?? .openai
        openAIKey = d.string(forKey: "openAIKey") ?? ""
        anthropicKey = d.string(forKey: "anthropicKey") ?? ""
        llmModel = d.string(forKey: "llmModel") ?? ""
        aiAssistance = d.object(forKey: "aiAssistance") as? Bool ?? true
        useTemporalCloud = d.bool(forKey: "useTemporalCloud")
        temporalAddress = d.string(forKey: "temporalAddress") ?? "localhost:7233"
        temporalNamespace = d.string(forKey: "temporalNamespace") ?? "default"
        temporalApiKey = d.string(forKey: "temporalApiKey") ?? ""
        chunkSeconds = d.object(forKey: "chunkSeconds") as? Double ?? 20
        analyzeEveryNChunks = d.object(forKey: "analyzeEveryNChunks") as? Int ?? 3
        warmupMinutes = d.object(forKey: "warmupMinutes") as? Double ?? 5
        maxActiveSuggestions = d.object(forKey: "maxActiveSuggestions") as? Int ?? 5
        outputDir = d.string(forKey: "outputDir") ?? ""
        whisperModel = d.string(forKey: "whisperModel") ?? "base"
        audioSampleRate = d.object(forKey: "audioSampleRate") as? Int ?? 16_000
        silenceTimeoutSeconds = d.object(forKey: "silenceTimeoutSeconds") as? Double ?? 300
        silencePeakThreshold = d.object(forKey: "silencePeakThreshold") as? Double ?? 0.02
        silenceRmsThreshold = d.object(forKey: "silenceRmsThreshold") as? Double ?? 0.005
    }

    func save() {
        d.set(role?.rawValue, forKey: "userRole")
        d.set(provider.rawValue, forKey: "llmProvider")
        d.set(openAIKey, forKey: "openAIKey")
        d.set(anthropicKey, forKey: "anthropicKey")
        d.set(llmModel, forKey: "llmModel")
        d.set(aiAssistance, forKey: "aiAssistance")
        d.set(useTemporalCloud, forKey: "useTemporalCloud")
        d.set(temporalAddress, forKey: "temporalAddress")
        d.set(temporalNamespace, forKey: "temporalNamespace")
        d.set(temporalApiKey, forKey: "temporalApiKey")
        d.set(chunkSeconds, forKey: "chunkSeconds")
        d.set(analyzeEveryNChunks, forKey: "analyzeEveryNChunks")
        d.set(warmupMinutes, forKey: "warmupMinutes")
        d.set(maxActiveSuggestions, forKey: "maxActiveSuggestions")
        d.set(outputDir, forKey: "outputDir")
        d.set(whisperModel, forKey: "whisperModel")
        d.set(audioSampleRate, forKey: "audioSampleRate")
        d.set(silenceTimeoutSeconds, forKey: "silenceTimeoutSeconds")
        d.set(silencePeakThreshold, forKey: "silencePeakThreshold")
        d.set(silenceRmsThreshold, forKey: "silenceRmsThreshold")
    }

    // MARK: - In-process Swift worker config

    /// Builds the `WorkerConfig` consumed by the in-process Swift worker. This is
    /// the single source of truth for the running app.
    func workerConfig() -> WorkerConfig {
        WorkerConfig(
            role: role?.rawValue,
            llmProvider: provider.rawValue,
            llmModel: llmModel.isEmpty ? nil : llmModel,
            openaiApiKey: openAIKey.isEmpty ? nil : openAIKey,
            anthropicApiKey: anthropicKey.isEmpty ? nil : anthropicKey,
            aiAssistanceEnabled: aiAssistance,
            analyzeEveryNChunks: analyzeEveryNChunks,
            analysisWarmupMinutes: warmupMinutes,
            maxActiveSuggestions: maxActiveSuggestions,
            chunkSeconds: chunkSeconds,
            silenceTimeoutSeconds: silenceTimeoutSeconds,
            silencePeakThreshold: Float(silencePeakThreshold),
            silenceRmsThreshold: Float(silenceRmsThreshold),
            audioSampleRate: audioSampleRate,
            whisperModel: whisperModel.isEmpty ? "base" : whisperModel,
            outputDir: outputDir.isEmpty ? "out" : outputDir
        )
    }
}
