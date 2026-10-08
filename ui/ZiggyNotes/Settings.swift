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
    }

    // MARK: - First-run hydration from an existing .env

    /// On first launch (before the user has saved settings), prime fields from the
    /// project's existing `.env` so the UI reflects the current configuration.
    func hydrateFromEnvIfNeeded(projectDir: String) {
        guard !d.bool(forKey: "ziggySettingsInitialized") else { return }
        let env = Self.parseEnvFile(projectDir: projectDir)
        if let v = env["USER_ROLE"], let r = Role(rawValue: v.lowercased()) { role = r }
        if let v = env["LLM_PROVIDER"], let p = Provider(rawValue: v.lowercased()) { provider = p }
        if let v = env["ZIGGY_AI_ASSISTANCE"] {
            aiAssistance = ["1", "true", "yes", "on"].contains(v.lowercased())
        }
        if let v = env["OPENAI_API_KEY"] { openAIKey = v }
        if let v = env["ANTHROPIC_API_KEY"] { anthropicKey = v }
        if let v = env["LLM_MODEL"] { llmModel = v }
        if let v = env["CHUNK_SECONDS"], let n = Double(v) { chunkSeconds = n }
        if let v = env["ANALYZE_EVERY_N_CHUNKS"], let n = Int(v) { analyzeEveryNChunks = n }
        if let v = env["ANALYSIS_WARMUP_MINUTES"], let n = Double(v) { warmupMinutes = n }
        if let v = env["MAX_ACTIVE_SUGGESTIONS"], let n = Int(v) { maxActiveSuggestions = n }
        if let v = env["ZIGGY_OUTPUT_DIR"] { outputDir = v }
        if let addr = env["TEMPORAL_ADDRESS"], !addr.isEmpty { temporalAddress = addr }
        if let ns = env["TEMPORAL_NAMESPACE"], !ns.isEmpty { temporalNamespace = ns }
        if let key = env["TEMPORAL_API_KEY"], !key.isEmpty {
            temporalApiKey = key
            useTemporalCloud = true
        }
        save()
        d.set(true, forKey: "ziggySettingsInitialized")
    }

    // MARK: - Environment the worker runs with

    /// Key/value pairs injected into the worker process and written to `.env`.
    func workerEnvironment() -> [String: String] {
        var e: [String: String] = [:]
        if let role { e["USER_ROLE"] = role.rawValue }
        e["LLM_PROVIDER"] = provider.rawValue
        e["ZIGGY_AI_ASSISTANCE"] = aiAssistance ? "true" : "false"
        if !openAIKey.isEmpty { e["OPENAI_API_KEY"] = openAIKey }
        if !anthropicKey.isEmpty { e["ANTHROPIC_API_KEY"] = anthropicKey }
        e["LLM_MODEL"] = llmModel
        e["CHUNK_SECONDS"] = Self.formatNumber(chunkSeconds)
        e["ANALYZE_EVERY_N_CHUNKS"] = String(analyzeEveryNChunks)
        e["ANALYSIS_WARMUP_MINUTES"] = Self.formatNumber(warmupMinutes)
        e["MAX_ACTIVE_SUGGESTIONS"] = String(maxActiveSuggestions)
        if !outputDir.isEmpty { e["ZIGGY_OUTPUT_DIR"] = outputDir }

        // Unique per-machine task queue so the spawned worker matches the Swift
        // client and users sharing a namespace never pick up each other's work.
        e["TEMPORAL_TASK_QUEUE"] = TemporalConfig.deviceTaskQueue
        if useTemporalCloud {
            e["TEMPORAL_ADDRESS"] = temporalAddress
            e["TEMPORAL_NAMESPACE"] = temporalNamespace
            e["TEMPORAL_API_KEY"] = temporalApiKey
            e["TEMPORAL_TLS"] = ""   // TLS implied by API key
        } else {
            // Local dev: explicitly clear cloud vars so stale values don't force Cloud.
            e["TEMPORAL_ADDRESS"] = "localhost:7233"
            e["TEMPORAL_NAMESPACE"] = "default"
            e["TEMPORAL_API_KEY"] = ""
            e["TEMPORAL_TLS"] = ""
        }
        return e
    }

    // MARK: - .env writing (merge)

    /// Merges `workerEnvironment()` into `<projectDir>/.env`, updating existing keys
    /// in place and appending any new ones while preserving comments / other keys.
    func writeEnv(projectDir: String) throws {
        let path = (projectDir as NSString).appendingPathComponent(".env")
        let fm = FileManager.default
        var lines: [String] = []
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            lines = existing.components(separatedBy: "\n")
        }

        var managed = workerEnvironment()
        // The task queue is derived per-machine and injected into the worker
        // process directly; it is intentionally NOT persisted to .env.
        managed.removeValue(forKey: "TEMPORAL_TASK_QUEUE")

        // Update existing KEY= lines.
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            if let value = managed[key] {
                lines[i] = "\(key)=\(Self.encodeValue(value))"
                managed.removeValue(forKey: key)
            }
        }

        // Append any keys not already present.
        if !managed.isEmpty {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("# Updated by Ziggy Notes settings")
            for key in managed.keys.sorted() {
                lines.append("\(key)=\(Self.encodeValue(managed[key]!))")
            }
        }

        let output = lines.joined(separator: "\n")
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        _ = fm // silence unused in some configs
    }

    // MARK: - Helpers

    private static func encodeValue(_ value: String) -> String {
        if value.isEmpty { return "" }
        let needsQuote = value.contains(" ") || value.contains("#") || value.contains("\t")
        if needsQuote {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func formatNumber(_ d: Double) -> String {
        if d == d.rounded() { return String(Int(d)) }
        return String(d)
    }

    static func parseEnvFile(projectDir: String) -> [String: String] {
        let path = (projectDir as NSString).appendingPathComponent(".env")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            out[key] = value
        }
        return out
    }
}
