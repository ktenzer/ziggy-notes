import Foundation
import AVFoundation
import CoreGraphics

/// Runs and supervises the in-process Swift Temporal worker (`WorkerRuntime`).
/// Previously this spawned the Python `worker.py`; now the worker is native and
/// runs inside the app, which also means audio capture is hands-off (no BlackHole).
///
/// The observable surface (`status`, `recentLog`) and the `start`/`stop`/
/// `requestMicrophoneAccess` API are preserved so the rest of the app is unchanged.
@MainActor
@Observable
final class WorkerManager {
    enum Status: Equatable {
        case idle
        case starting
        case running
        case failed(String)
        case stopped
    }

    enum WorkerError: Error, CustomStringConvertible {
        case startupFailed(String)

        var description: String {
            switch self {
            case .startupFailed(let s): return "Worker failed to start:\n\(s)"
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var recentLog: String = ""

    private let readyMarker = "ziggy worker started"
    private let runtime = WorkerRuntime()

    // MARK: - Permissions

    /// Requests microphone access (needed by AVAudioEngine mic capture).
    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Requests Screen Recording access (needed by ScreenCaptureKit system-audio
    /// capture). Best-effort: prompts on first use and returns current grant.
    @discardableResult
    func requestScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - Lifecycle

    /// Starts the in-process worker against `temporal`, configured by `worker`.
    func start(temporal: TemporalConfig, worker workerConfig: WorkerConfig) async throws {
        if status == .running || status == .starting { return }
        status = .starting
        recentLog = ""

        // Route worker/SDK log lines into the observable `recentLog` ring buffer.
        WorkerLogStore.shared.onAppend = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }

        do {
            try await runtime.start(temporal: temporal, worker: workerConfig)
            status = .running
        } catch {
            status = .failed(WorkerError.startupFailed(error.localizedDescription).description)
            throw WorkerError.startupFailed(error.localizedDescription)
        }
    }

    /// Stops the in-process worker.
    func stop() {
        Task { await runtime.stop() }
        WorkerLogStore.shared.onAppend = nil
        if status == .running || status == .starting {
            status = .stopped
        }
    }

    // MARK: - Internal

    private func appendLog(_ line: String) {
        recentLog += line + "\n"
        if recentLog.count > 8000 {
            recentLog = String(recentLog.suffix(8000))
        }
        if line.contains(readyMarker), status == .starting {
            status = .running
        }
    }
}
