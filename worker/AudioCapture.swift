import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import Logging

/// Captures BOTH the local microphone (the Temporal rep) and the system audio
/// output (remote participants / "the customer") natively, with no third-party
/// loopback driver:
///
///   * mic    -> `AVAudioEngine` input node
///   * output -> `ScreenCaptureKit` system-audio capture (macOS 13+)
///
/// Both streams are converted to mono Float32 at the target sample rate (16 kHz)
/// and accumulated until the capture activity drains them once per chunk. This is
/// the Swift analogue of the Python `_Recorder` pair, but hands-off: the user
/// never configures an audio device, so it works with AirPods or any output.
final class AudioCapture: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    private let targetFormat: AVAudioFormat
    private let targetSampleRate: Double
    private let logger: Logger

    private let lock = NSLock()
    private var micFrames: [Float] = []
    private var systemFrames: [Float] = []

    private let engine = AVAudioEngine()
    private var scStream: SCStream?

    private(set) var micCaptured = false
    private(set) var systemCaptured = false

    init(sampleRate: Double, logger: Logger) {
        self.targetSampleRate = sampleRate
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        self.logger = logger
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        startMic()
        await startSystemAudio()
    }

    private func startMic() {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.warning("microphone unavailable (no input format)")
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convert(buffer)
            if !samples.isEmpty {
                self.lock.lock(); self.micFrames.append(contentsOf: samples); self.lock.unlock()
            }
        }
        do {
            engine.prepare()
            try engine.start()
            micCaptured = true
            logger.info("microphone capture started (mic=Temporal)")
        } catch {
            logger.warning("could not start microphone engine: \(error)")
            input.removeTap(onBus: 0)
        }
    }

    private func startSystemAudio() async {
        // Only touch ScreenCaptureKit if permission is ALREADY granted. Calling
        // SCShareableContent without permission pops the system "would like to
        // record" modal — and would do so on EVERY note. The one-time request is
        // handled once at app startup (WorkerManager.requestScreenCaptureAccess);
        // here we stay silent until the grant is actually in effect. (For Screen
        // Recording the grant only takes effect after the app is reopened, so a
        // just-granted permission won't register until the next launch.)
        guard CGPreflightScreenCaptureAccess() else {
            logger.warning("Screen Recording not granted yet; skipping system-audio (customer) capture. Grant it in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen the app. (Mic capture is unaffected.)")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                logger.warning("no display available for system-audio capture; customer audio will NOT be captured")
                return
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = Int(targetSampleRate)
            cfg.channelCount = 1
            cfg.excludesCurrentProcessAudio = true   // don't record our own output
            // Minimal video: we only want audio, but SCStream requires a video config.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "ziggy.sckit.audio"))
            try await stream.startCapture()
            scStream = stream
            systemCaptured = true
            logger.info("system-audio capture started (output=Customer) via ScreenCaptureKit")
        } catch {
            logger.warning("could not start system-audio capture (\(error)); customer audio will NOT be captured. Grant Screen Recording permission in System Settings > Privacy.")
            scStream = nil
        }
    }

    func stop() async {
        if micCaptured {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }
    }

    // MARK: - Draining

    func isActive(_ source: String) -> Bool {
        source == ZiggySource.mic ? micCaptured : systemCaptured
    }

    func drain(_ source: String) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if source == ZiggySource.mic {
            let f = micFrames; micFrames = []; return f
        } else {
            let f = systemFrames; systemFrames = []; return f
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = convert(buffer)
        if !samples.isEmpty {
            lock.lock(); systemFrames.append(contentsOf: samples); lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.warning("system-audio stream stopped with error: \(error)")
    }

    // MARK: - Conversion helpers

    /// Convert an arbitrary-format PCM buffer to mono Float32 at the target rate.
    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let inFormat = buffer.format
        if inFormat.sampleRate == targetSampleRate && inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32, let ch = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }
        guard let conv = AVAudioConverter(from: inFormat, to: targetFormat) else { return [] }
        let ratio = targetSampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }
        if status == .error { logger.warning("audio convert error: \(error?.localizedDescription ?? "?")"); return [] }
        guard let ch = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Build an `AVAudioPCMBuffer` from a CoreMedia audio sample buffer.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
              let format = AVAudioFormat(streamDescription: asbdPtr) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let err = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return err == noErr ? buffer : nil
    }
}
