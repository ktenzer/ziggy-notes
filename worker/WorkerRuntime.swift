import Foundation
import Logging
import Temporal

/// Hosts the in-process Temporal worker: a `TemporalWorker` (serving the
/// `MeetingWorkflow` + Ziggy activities) plus a `TemporalClient` the capture
/// activity uses to signal `add_transcript_chunk`. Both run together for the
/// lifetime of the app, replacing the previously-spawned Python worker process.
actor WorkerRuntime {
    private var runTask: Task<Void, Never>?
    private var client: TemporalClient?

    var isRunning: Bool { runTask != nil }

    /// Starts the worker + client and returns once they've had a moment to come
    /// up. Safe to call once; subsequent calls are no-ops until `stop()`.
    func start(temporal: TemporalConfig, worker workerConfig: WorkerConfig) async throws {
        guard runTask == nil else { return }

        // Publish the config the workflow + activities read.
        WorkerConfig.current = workerConfig

        let logger = ZiggyLog.make(label: "ziggy.worker")

        let clientConfig = TemporalClient.Configuration(
            instrumentation: .init(serverHostname: temporal.host),
            namespace: temporal.namespace,
            apiKey: temporal.apiKey
        )
        let newClient = try TemporalClient(
            target: .dns(host: temporal.host, port: temporal.port),
            transportSecurity: temporal.useTLS ? .tls : .plaintext,
            configuration: clientConfig,
            logger: logger
        )

        let activities = ZiggyActivities(config: workerConfig, client: newClient)
        let workerConfiguration = TemporalWorker.Configuration(
            namespace: temporal.namespace,
            taskQueue: temporal.taskQueue,
            instrumentation: .init(serverHostname: temporal.host),
            apiKey: temporal.apiKey
        )
        let worker = try TemporalWorker(
            configuration: workerConfiguration,
            target: .dns(host: temporal.host, port: temporal.port),
            transportSecurity: temporal.useTLS ? .tls : .plaintext,
            activityContainers: activities,
            activities: [],
            workflows: [MeetingWorkflow.self, AskMeetingWorkflow.self],
            logger: logger
        )

        self.client = newClient
        runTask = Task { [worker, newClient] in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await worker.run() }
                    group.addTask { try await newClient.run() }
                    try await group.waitForAll()
                }
            } catch {
                logger.error("worker runtime stopped: \(error)")
            }
        }

        // Give the gRPC transport + worker a brief moment to register.
        try? await Task.sleep(for: .seconds(1))
        logger.info("ziggy worker started on task queue \(temporal.taskQueue)")
    }

    func stop() {
        client?.beginGracefulShutdown()
        runTask?.cancel()
        runTask = nil
        client = nil
    }
}
