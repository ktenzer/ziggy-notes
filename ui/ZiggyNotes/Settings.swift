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

    // LLM
    var provider: Provider = .openai
    var openAIKey: String = ""
    var anthropicKey: String = ""
    var llmModel: String = ""

    // Temporal
    var useTemporalCloud: Bool = false
    var temporalAddress: String = "localhost:7233"
    var temporalNamespace: String = "default"
    var temporalTaskQueue: String = "ziggy-notes-tq"
    var temporalApiKey: String = ""

    // App configuration
    var chunkSeconds: Double = 20
    var analyzeEveryNChunks: Int = 3

    // Output
    var outputDir: String = ""

    private let d = UserDefaults.standard

    init() { load() }

    // MARK: - Validation

    var apiKeyForProvider: String {
        provider == .openai ? openAIKey : anthropicKey
    }

    var isValid: Bool {
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
        provider = Provider(rawValue: d.string(forKey: "llmProvider") ?? "openai") ?? .openai
        openAIKey = d.string(forKey: "openAIKey") ?? ""
        anthropicKey = d.string(forKey: "anthropicKey") ?? ""
        llmModel = d.string(forKey: "llmModel") ?? ""
        useTemporalCloud = d.bool(forKey: "useTemporalCloud")
        temporalAddress = d.string(forKey: "temporalAddress") ?? "localhost:7233"
        temporalNamespace = d.string(forKey: "temporalNamespace") ?? "default"
        temporalTaskQueue = d.string(forKey: "temporalTaskQueue") ?? "ziggy-notes-tq"
        temporalApiKey = d.string(forKey: "temporalApiKey") ?? ""
        chunkSeconds = d.object(forKey: "chunkSeconds") as? Double ?? 20
        analyzeEveryNChunks = d.object(forKey: "analyzeEveryNChunks") as? Int ?? 3
        outputDir = d.string(forKey: "outputDir") ?? ""
    }

    func save() {
        d.set(provider.rawValue, forKey: "llmProvider")
        d.set(openAIKey, forKey: "openAIKey")
        d.set(anthropicKey, forKey: "anthropicKey")
        d.set(llmModel, forKey: "llmModel")
        d.set(useTemporalCloud, forKey: "useTemporalCloud")
        d.set(temporalAddress, forKey: "temporalAddress")
        d.set(temporalNamespace, forKey: "temporalNamespace")
        d.set(temporalTaskQueue, forKey: "temporalTaskQueue")
        d.set(temporalApiKey, forKey: "temporalApiKey")
        d.set(chunkSeconds, forKey: "chunkSeconds")
        d.set(analyzeEveryNChunks, forKey: "analyzeEveryNChunks")
        d.set(outputDir, forKey: "outputDir")
    }

    // MARK: - First-run hydration from an existing .env

    /// On first launch (before the user has saved settings), prime fields from the
    /// project's existing `.env` so the UI reflects the current configuration.
    func hydrateFromEnvIfNeeded(projectDir: String) {
        guard !d.bool(forKey: "ziggySettingsInitialized") else { return }
        let env = Self.parseEnvFile(projectDir: projectDir)
        if let v = env["LLM_PROVIDER"], let p = Provider(rawValue: v.lowercased()) { provider = p }
        if let v = env["OPENAI_API_KEY"] { openAIKey = v }
        if let v = env["ANTHROPIC_API_KEY"] { anthropicKey = v }
        if let v = env["LLM_MODEL"] { llmModel = v }
        if let v = env["CHUNK_SECONDS"], let n = Double(v) { chunkSeconds = n }
        if let v = env["ANALYZE_EVERY_N_CHUNKS"], let n = Int(v) { analyzeEveryNChunks = n }
        if let v = env["ZIGGY_OUTPUT_DIR"] { outputDir = v }
        if let addr = env["TEMPORAL_ADDRESS"], !addr.isEmpty { temporalAddress = addr }
        if let ns = env["TEMPORAL_NAMESPACE"], !ns.isEmpty { temporalNamespace = ns }
        if let tq = env["TEMPORAL_TASK_QUEUE"], !tq.isEmpty { temporalTaskQueue = tq }
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
        e["LLM_PROVIDER"] = provider.rawValue
        if !openAIKey.isEmpty { e["OPENAI_API_KEY"] = openAIKey }
        if !anthropicKey.isEmpty { e["ANTHROPIC_API_KEY"] = anthropicKey }
        e["LLM_MODEL"] = llmModel
        e["CHUNK_SECONDS"] = Self.formatNumber(chunkSeconds)
        e["ANALYZE_EVERY_N_CHUNKS"] = String(analyzeEveryNChunks)
        if !outputDir.isEmpty { e["ZIGGY_OUTPUT_DIR"] = outputDir }

        if useTemporalCloud {
            e["TEMPORAL_ADDRESS"] = temporalAddress
            e["TEMPORAL_NAMESPACE"] = temporalNamespace
            e["TEMPORAL_TASK_QUEUE"] = temporalTaskQueue.isEmpty ? "ziggy-notes-tq" : temporalTaskQueue
            e["TEMPORAL_API_KEY"] = temporalApiKey
            e["TEMPORAL_TLS"] = ""   // TLS implied by API key
        } else {
            // Local dev: explicitly clear cloud vars so stale values don't force Cloud.
            e["TEMPORAL_ADDRESS"] = "localhost:7233"
            e["TEMPORAL_NAMESPACE"] = "default"
            e["TEMPORAL_TASK_QUEUE"] = temporalTaskQueue.isEmpty ? "ziggy-notes-tq" : temporalTaskQueue
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
