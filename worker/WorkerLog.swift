import Foundation
import Logging

/// Process-wide sink that captures every log line emitted by the in-process
/// worker (SDK + our own) so the app can show them in the Logs view -- the same
/// role the Python worker's stdout pipe played for `WorkerManager`.
final class WorkerLogStore: @unchecked Sendable {
    static let shared = WorkerLogStore()

    private let lock = NSLock()
    private var _onAppend: (@Sendable (String) -> Void)?

    /// Installed by `WorkerManager` to receive each formatted log line (delivered
    /// on an arbitrary thread; the manager hops to the main actor).
    var onAppend: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onAppend }
        set { lock.lock(); _onAppend = newValue; lock.unlock() }
    }

    func append(_ line: String) {
        let cb = onAppend
        cb?(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// A `swift-log` handler that formats records and forwards them to
/// `WorkerLogStore.shared`. Keeps output compact (level + message), close to the
/// Python worker's logging format the UI expects.
struct ZiggyLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    let label: String

    init(label: String) { self.label = label }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        WorkerLogStore.shared.append("[\(level)] \(message)")
    }
}

/// Factory for loggers that feed the shared sink. Used for the worker, client,
/// and any helper that runs outside an activity/workflow task-local context.
enum ZiggyLog {
    static func make(label: String, level: Logger.Level = .info) -> Logger {
        var logger = Logger(label: label) { ZiggyLogHandler(label: $0) }
        logger.logLevel = level
        return logger
    }

    /// Shared logger for audio callbacks and other non-context code paths.
    static let shared = make(label: "ziggy.worker")
}
