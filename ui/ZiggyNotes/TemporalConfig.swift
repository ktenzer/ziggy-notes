import Foundation

/// Connection configuration resolved from environment variables, mirroring the
/// Python `ziggy/config.py` logic:
///
///   - `TEMPORAL_ADDRESS`   (default `localhost:7233`)
///   - `TEMPORAL_NAMESPACE` (default `default`)
///   - `TEMPORAL_TASK_QUEUE`(default `ziggy-notes-tq`)
///   - `TEMPORAL_API_KEY`   -> Temporal Cloud (Bearer auth + TLS)
///   - `TEMPORAL_TLS`       -> force TLS for self-hosted ("1"/"true"/"yes"/"on")
struct TemporalConfig: Sendable {
    var address: String
    var namespace: String
    var taskQueue: String
    var apiKey: String?
    var useTLS: Bool

    static let defaultAddress = "localhost:7233"
    static let defaultNamespace = "default"
    static let defaultTaskQueue = "ziggy-notes-tq"

    static func fromEnvironment() -> TemporalConfig {
        let env = ProcessInfo.processInfo.environment

        func nonEmpty(_ key: String) -> String? {
            guard let v = env[key], !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }

        let address = nonEmpty("TEMPORAL_ADDRESS") ?? defaultAddress
        let namespace = nonEmpty("TEMPORAL_NAMESPACE") ?? defaultNamespace
        let taskQueue = nonEmpty("TEMPORAL_TASK_QUEUE") ?? defaultTaskQueue
        let apiKey = nonEmpty("TEMPORAL_API_KEY")

        let tlsFlag = (nonEmpty("TEMPORAL_TLS") ?? "").lowercased()
        let tlsRequested = ["1", "true", "yes", "on"].contains(tlsFlag)
        // Cloud (api key) always uses TLS; self-hosted uses TLS only if requested.
        let useTLS = (apiKey != nil) || tlsRequested

        return TemporalConfig(
            address: address,
            namespace: namespace,
            taskQueue: taskQueue,
            apiKey: apiKey,
            useTLS: useTLS
        )
    }

    /// Builds a connection config from user Settings (localhost vs Temporal Cloud).
    @MainActor
    static func from(settings: Settings) -> TemporalConfig {
        if settings.useTemporalCloud {
            return TemporalConfig(
                address: settings.temporalAddress,
                namespace: settings.temporalNamespace,
                taskQueue: settings.temporalTaskQueue.isEmpty ? defaultTaskQueue : settings.temporalTaskQueue,
                apiKey: settings.temporalApiKey.isEmpty ? nil : settings.temporalApiKey,
                useTLS: true
            )
        }
        return TemporalConfig(
            address: defaultAddress,
            namespace: defaultNamespace,
            taskQueue: settings.temporalTaskQueue.isEmpty ? defaultTaskQueue : settings.temporalTaskQueue,
            apiKey: nil,
            useTLS: false
        )
    }

    var host: String {
        guard let h = address.split(separator: ":", maxSplits: 1).first else { return "localhost" }
        return String(h)
    }

    var port: Int {
        let parts = address.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let p = Int(parts[1]) else { return 7233 }
        return p
    }

    /// True when connecting to Temporal Cloud via API key.
    var isCloud: Bool { apiKey != nil }

    /// Human-readable description for the UI connection banner.
    var summary: String {
        if isCloud { return "Temporal Cloud · \(namespace) · \(address)" }
        return "\(useTLS ? "TLS" : "local") · \(namespace) · \(address)"
    }
}

/// Workflow IDs follow the Python convention `workflow_id_for()` in `config.py`.
func workflowId(for meetingId: String) -> String {
    "ziggy-meeting-\(meetingId)"
}

/// Registered workflow type name on the Python worker.
let meetingWorkflowName = "MeetingWorkflow"
