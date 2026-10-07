import Foundation
import Logging
import Temporal

/// Thin actor wrapper around the Apple Swift Temporal SDK client.
///
/// Responsible for connecting (localhost dev server or Temporal Cloud), starting
/// the `MeetingWorkflow`, sending stop/abort signals, and running the `get_updates`
/// polling query. All workflow IDs follow the `ziggy-meeting-<id>` convention used
/// by the Python backend.
actor ZiggyClient {
    enum ClientError: Error, CustomStringConvertible {
        case notConnected
        case workflowNotFound

        var description: String {
            switch self {
            case .notConnected: return "Temporal client is not connected."
            case .workflowNotFound: return "Workflow not found."
            }
        }
    }

    let config: TemporalConfig
    private var client: TemporalClient?
    private var runTask: Task<Void, Never>?

    init(config: TemporalConfig = .fromEnvironment()) {
        self.config = config
    }

    /// Establishes the connection and starts the client's background run loop.
    /// Safe to call multiple times; subsequent calls are no-ops.
    func connect() async throws {
        guard client == nil else { return }

        var logger = Logger(label: "ziggy.temporal")
        logger.logLevel = .warning

        let configuration = TemporalClient.Configuration(
            instrumentation: .init(serverHostname: config.host),
            namespace: config.namespace,
            apiKey: config.apiKey
        )

        // `transportSecurity` and `target` use leading-dot member lookup against the
        // init's parameter types so we don't need the transport type names in scope.
        let newClient = try TemporalClient(
            target: .dns(host: config.host, port: config.port),
            transportSecurity: config.useTLS ? .tls : .plaintext,
            configuration: configuration,
            logger: logger
        )

        // The client must be run to service requests (see SDK ServiceLifecycle docs).
        runTask = Task { [newClient] in
            do { try await newClient.run() } catch { /* shutdown / cancellation */ }
        }
        client = newClient

        // Give the gRPC transport a brief moment to come up before first RPC.
        try? await Task.sleep(for: .milliseconds(250))
    }

    func shutdown() {
        client?.beginGracefulShutdown()
        runTask?.cancel()
        runTask = nil
        client = nil
    }

    private func requireClient() throws -> TemporalClient {
        guard let client else { throw ClientError.notConnected }
        return client
    }

    // MARK: - Operations

    /// Starts a new meeting workflow and returns its workflow ID.
    @discardableResult
    func startMeeting(_ input: MeetingInput) async throws -> String {
        let client = try requireClient()
        let wfId = workflowId(for: input.meetingId)
        _ = try await client.startWorkflow(
            name: meetingWorkflowName,
            options: WorkflowOptions(id: wfId, taskQueue: config.taskQueue),
            input: input
        )
        return wfId
    }

    /// Signals the workflow to stop (and optionally abort for an immediate finish).
    func stopMeeting(meetingId: String, abort: Bool = false) async throws {
        let client = try requireClient()
        let handle = client.untypedWorkflowHandle(id: workflowId(for: meetingId))
        try await handle.signal(signalName: abort ? "abort" : "stop_recording")
    }

    /// Runs the incremental `get_updates` query. Returns `nil` if the workflow does
    /// not exist (e.g. never started or purged), allowing callers to treat it as gone.
    func getUpdates(meetingId: String, sinceChunk: Int, sinceSuggestion: Int) async throws -> MeetingUpdatesDTO? {
        let client = try requireClient()
        let handle = client.untypedWorkflowHandle(id: workflowId(for: meetingId))
        do {
            let cursor = UpdatesCursor(sinceChunk: sinceChunk, sinceSuggestion: sinceSuggestion)
            let updates: MeetingUpdatesDTO = try await handle.query(
                queryName: "get_updates",
                input: cursor,
                resultTypes: MeetingUpdatesDTO.self
            )
            return updates
        } catch {
            if Self.isGone(error) { return nil }
            throw error
        }
    }

    /// True when an error indicates the workflow is no longer running (not found,
    /// already completed, or terminated) — i.e. a stop/query can't reach it.
    static func isGone(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("not found")
            || text.contains("notfound")
            || text.contains("already completed")
            || text.contains("workflow execution already completed")
            || text.contains("terminated")
    }
}
