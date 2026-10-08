import Foundation
import Logging
import WhisperKit

/// On-device speech-to-text using WhisperKit (CoreML Whisper). The `base` model
/// is bundled in the app so the first run is fully offline and hands-off -- no
/// download, no setup.
///
/// The capture activity awaits `load()` once and then `transcribe(_:)` for each
/// window sequentially, so there is never concurrent access to the underlying
/// (non-Sendable) WhisperKit instance; we opt out of strict-concurrency checking
/// on that basis.
final class Transcriber: @unchecked Sendable {
    private let modelName: String
    private let logger: Logger
    private var whisper: WhisperKit?

    init(modelName: String, logger: Logger) {
        self.modelName = modelName
        self.logger = logger
    }

    /// Loads the model once. Prefers a model folder bundled in the app Resources
    /// (fully offline); otherwise falls back to WhisperKit's managed download.
    func load() async throws {
        guard whisper == nil else { return }
        let bundledFolder = Self.bundledModelFolder(modelName)
        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: bundledFolder,
            download: bundledFolder == nil
        )
        if let f = bundledFolder {
            logger.info("loading bundled WhisperKit model '\(modelName)' from \(f)")
        } else {
            logger.info("bundled WhisperKit model not found; downloading '\(modelName)' on first run")
        }
        whisper = try await WhisperKit(config)
    }

    /// Transcribe one mono 16 kHz Float32 window into a single trimmed string.
    func transcribe(_ audio: [Float], language: String?) async throws -> String {
        guard let whisper else { return "" }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 0,
            usePrefillPrompt: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Locates a bundled CoreML model folder for the given Whisper model name.
    /// We bundle it under `Resources/whisper-models/openai_whisper-<name>`.
    private static func bundledModelFolder(_ model: String) -> String? {
        let fm = FileManager.default
        let candidates = [
            "openai_whisper-\(model)",
            model,
        ]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "whisper-models"),
               fm.fileExists(atPath: url.path) {
                return url.path
            }
        }
        // Also accept a flat bundled folder named exactly like the model.
        if let url = Bundle.main.url(forResource: "openai_whisper-\(model)", withExtension: nil),
           fm.fileExists(atPath: url.path) {
            return url.path
        }
        return nil
    }
}
