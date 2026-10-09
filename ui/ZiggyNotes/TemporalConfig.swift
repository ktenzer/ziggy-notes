import Foundation
import IOKit
import CryptoKit

/// Per-machine identity used to make the Temporal task queue unique to this Mac,
/// so many users sharing one namespace never pick up each other's work (and a
/// workflow is only ever run by the worker on the machine that captured its
/// audio).
enum MachineIdentity {
    /// The Mac's hardware UUID (`IOPlatformUUID`), stable across restarts and
    /// reinstalls. Returns nil if it can't be read.
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return cf.takeRetainedValue() as? String
    }

    /// A short, stable, non-PII tag derived from the hardware UUID (so the raw
    /// hardware UUID isn't exposed in a shared namespace). Falls back to a
    /// persisted random id if the hardware UUID is unavailable.
    static let shortTag: String = {
        let base = hardwareUUID() ?? fallbackId()
        let digest = SHA256.hash(data: Data(base.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()  // 12 hex chars
    }()

    private static func fallbackId() -> String {
        let key = "ziggyMachineFallbackId"
        let d = UserDefaults.standard
        if let s = d.string(forKey: key), !s.isEmpty { return s }
        let s = UUID().uuidString
        d.set(s, forKey: key)
        return s
    }
}

/// Connection configuration resolved from environment variables, mirroring the
/// Python `ziggy/config.py` logic:
///
///   - `TEMPORAL_ADDRESS`   (default `localhost:7233`)
///   - `TEMPORAL_NAMESPACE` (default `default`)
///   - `TEMPORAL_TASK_QUEUE`(default: per-machine `ziggy-notes-tq-<machine tag>`)
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

    /// Task queue unique to this machine (shared-namespace safe). Both the Swift
    /// client and the spawned Python worker use this exact value.
    static var deviceTaskQueue: String { "ziggy-notes-tq-\(MachineIdentity.shortTag)" }

    static func fromEnvironment() -> TemporalConfig {
        let env = ProcessInfo.processInfo.environment

        func nonEmpty(_ key: String) -> String? {
            guard let v = env[key], !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }

        let address = nonEmpty("TEMPORAL_ADDRESS") ?? defaultAddress
        let namespace = nonEmpty("TEMPORAL_NAMESPACE") ?? defaultNamespace
        let taskQueue = nonEmpty("TEMPORAL_TASK_QUEUE") ?? deviceTaskQueue
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
                taskQueue: deviceTaskQueue,
                apiKey: settings.temporalApiKey.isEmpty ? nil : settings.temporalApiKey,
                useTLS: true
            )
        }
        return TemporalConfig(
            address: defaultAddress,
            namespace: defaultNamespace,
            taskQueue: deviceTaskQueue,
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

    /// The Temporal Cloud Account ID, derived from the gRPC address which is in
    /// the form `<namespace>.<account>.tmprl.cloud:7233`. Returns nil when the
    /// address isn't a recognizable Temporal Cloud endpoint.
    var cloudAccountId: String? {
        let labels = host.split(separator: ".").map(String.init)
        // Expect: [<namespace>, <account>, "tmprl", "cloud"]
        guard labels.count >= 4,
              labels[labels.count - 2] == "tmprl",
              labels[labels.count - 1] == "cloud" else { return nil }
        return labels[labels.count - 3]
    }

    /// Fully-qualified Temporal Cloud Namespace ID (`namespaceName.accountId`),
    /// which the Cloud Web UI requires in its URL path. If the configured
    /// namespace already includes the account suffix it is used as-is; otherwise
    /// the account ID is appended from the address when available.
    var cloudNamespaceId: String {
        if namespace.contains(".") { return namespace }
        if let account = cloudAccountId { return "\(namespace).\(account)" }
        return namespace
    }

    /// Human-readable description for the UI connection banner.
    var summary: String {
        if isCloud { return "Temporal Cloud · \(namespace) · \(address)" }
        return "\(useTLS ? "TLS" : "local") · \(namespace) · \(address)"
    }

    /// URL to this meeting's workflow in the Temporal Web UI, so the user can open
    /// it in a browser. Temporal Cloud uses `cloud.temporal.io`; the local dev
    /// server (`temporal server start-dev`) serves its UI on port 8233.
    func workflowWebURL(meetingId: String) -> URL? {
        let wf = workflowId(for: meetingId)
        let encodedWf = wf.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? wf
        if isCloud {
            // Temporal Cloud requires the fully-qualified Namespace ID
            // (`namespaceName.accountId`) in the Web UI path.
            let ns = cloudNamespaceId
            let encodedNs = ns.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ns
            return URL(string: "https://cloud.temporal.io/namespaces/\(encodedNs)/workflows/\(encodedWf)")
        }
        let encodedNs = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace
        return URL(string: "http://\(host):8233/namespaces/\(encodedNs)/workflows/\(encodedWf)")
    }
}

/// Workflow IDs follow the Python convention `workflow_id_for()` in `config.py`.
func workflowId(for meetingId: String) -> String {
    "ziggy-meeting-\(meetingId)"
}

/// Registered meeting workflow type name.
let meetingWorkflowName = "MeetingWorkflow"

/// Ask-anything workflow IDs: one per question, grouped by meeting note so it's
/// clear in Temporal which note each exchange belongs to
/// (e.g. `ziggy-ask-<meetingId>-1`, `-2`, …).
func askWorkflowId(for meetingId: String, seq: Int) -> String {
    "ziggy-ask-\(meetingId)-\(seq)"
}

/// Registered ask workflow type name.
let askMeetingWorkflowName = "AskMeetingWorkflow"
