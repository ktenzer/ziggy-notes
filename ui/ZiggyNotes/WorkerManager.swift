import Foundation
import AVFoundation

/// Launches and supervises the Python Temporal worker (`uv run python worker.py`)
/// from within the app. The app only proceeds once the worker reports that it has
/// started (the "ziggy worker started" log line). The worker is terminated when the
/// app quits.
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
        case missingProject(String)
        case missingVenv(String)
        case startupFailed(String)
        case timeout

        var description: String {
            switch self {
            case .missingProject(let p): return "worker.py not found in project directory: \(p)"
            case .missingVenv(let p):
                return "Python virtual environment not found at:\n\(p)\n\nRun `uv sync` in the project directory first."
            case .startupFailed(let s): return "Worker failed to start:\n\(s)"
            case .timeout: return "Timed out waiting for the worker to start."
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var recentLog: String = ""

    private let readyMarker = "ziggy worker started"
    private let startupTimeout: Duration = .seconds(120)

    private var process: Process?
    private var readTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var didResume = false

    // MARK: - Project location

    /// Resolved project directory containing `worker.py`. Order of preference:
    /// explicit UserDefaults override, `ZIGGY_PROJECT_DIR` env, then the repo path.
    var projectDir: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "ziggyProjectDir"), !saved.isEmpty {
                return saved
            }
            if let env = ProcessInfo.processInfo.environment["ZIGGY_PROJECT_DIR"], !env.isEmpty {
                return env
            }
            return WorkerManager.defaultProjectDir
        }
        set { UserDefaults.standard.set(newValue, forKey: "ziggyProjectDir") }
    }

    static var defaultProjectDir: String {
        // The app bundle lives under <repo>/ui/... during development; walk up to find worker.py.
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: Bundle.main.bundlePath)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("worker.py")
            if fm.fileExists(atPath: candidate.path) { return dir.path }
            dir.deleteLastPathComponent()
        }
        // Fallback to the known development path.
        return NSString(string: "~/temporal/ziggy-notes").expandingTildeInPath
    }

    var workerScriptExists: Bool {
        FileManager.default.fileExists(atPath: (projectDir as NSString).appendingPathComponent("worker.py"))
    }

    /// Path to the project's uv-managed interpreter. We launch this directly (rather
    /// than `uv run …`) so the supervised process *is* the worker — terminating it
    /// reliably stops the worker instead of leaving an orphaned child behind.
    var venvPythonPath: String {
        (projectDir as NSString).appendingPathComponent(".venv/bin/python")
    }

    var venvExists: Bool {
        FileManager.default.fileExists(atPath: venvPythonPath)
    }

    // MARK: - Microphone permission

    /// Requests microphone access. Because the app spawns the capture process, the
    /// worker's mic usage is attributed to this (responsible) app.
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

    // MARK: - Lifecycle

    func start(environment extraEnv: [String: String] = [:]) async throws {
        if status == .running || status == .starting { return }
        guard workerScriptExists else {
            status = .failed(WorkerError.missingProject(projectDir).description)
            throw WorkerError.missingProject(projectDir)
        }
        guard venvExists else {
            status = .failed(WorkerError.missingVenv(venvPythonPath).description)
            throw WorkerError.missingVenv(venvPythonPath)
        }

        status = .starting
        recentLog = ""
        didResume = false

        // Launch the venv interpreter directly: the process we track is the worker
        // itself, so terminating it stops the worker (no orphaned `uv`/python child).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPythonPath)
        proc.arguments = ["worker.py"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }   // Settings override stale shell vars
        env["PYTHONUNBUFFERED"] = "1"            // flush logs promptly so we see the ready marker
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let readHandle = pipe.fileHandleForReading

        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(code: code) }
        }

        self.process = proc

        do {
            try proc.run()
        } catch {
            status = .failed(error.localizedDescription)
            self.process = nil
            throw WorkerError.startupFailed(error.localizedDescription)
        }

        // Stream the worker's combined stdout/stderr and watch for the ready marker.
        readTask = Task { [weak self, readHandle] in
            do {
                for try await line in readHandle.bytes.lines {
                    await self?.appendLog(line)
                }
            } catch {
                // Handle closed on process exit; termination handler covers status.
            }
        }

        // Schedule a startup timeout on the main actor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.startupTimeout)
            if self.status == .starting {
                self.process?.terminate()
                self.status = .failed(WorkerError.timeout.description)
                self.resumeReady(throwing: WorkerError.timeout)
            }
        }

        // Wait until the worker is ready (or startup fails / times out).
        // This runs in the main-actor context of `start()`, so storing the
        // continuation on `self` is safe.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyContinuation = cont
        }
    }

    /// Stops the worker and blocks briefly until it exits. Safe to call on app
    /// termination (runs on the main thread during quit). Sends SIGTERM for a
    /// graceful shutdown, then SIGKILL if the worker doesn't exit in time.
    func stop() {
        readTask?.cancel()
        readTask = nil

        if let proc = process, proc.isRunning {
            proc.terminate() // SIGTERM -> worker.py handles graceful shutdown

            // Wait up to ~4s for a clean exit, then force-kill.
            let deadline = Date().addingTimeInterval(4)
            while proc.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                proc.waitUntilExit()
            }
        }

        process = nil
        if status == .running || status == .starting {
            status = .stopped
        }
        resumeReady(throwing: nil) // no-op if already resumed
    }

    // MARK: - Internal

    private func appendLog(_ line: String) {
        recentLog += line + "\n"
        if recentLog.count > 8000 {
            recentLog = String(recentLog.suffix(8000))
        }
        if line.contains(readyMarker), status == .starting {
            status = .running
            resumeReady(throwing: nil)
        }
    }

    private func handleTermination(code: Int32) {
        switch status {
        case .starting:
            let tail = String(recentLog.suffix(2000))
            let err = WorkerError.startupFailed(tail.isEmpty ? "exit code \(code)" : tail)
            status = .failed(err.description)
            resumeReady(throwing: err)
        case .running:
            status = .stopped
        default:
            break
        }
        process = nil
    }

    private func resumeReady(throwing error: Error?) {
        guard !didResume, let cont = readyContinuation else { return }
        didResume = true
        readyContinuation = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }
}
