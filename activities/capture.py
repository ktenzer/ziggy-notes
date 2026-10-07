"""``capture_audio`` -- the long-running macOS audio capture Activity.

This is the one place real-time, non-deterministic work happens. It runs for the
whole meeting as a single heartbeating Activity (so there are no gaps between
chunks), records BOTH the microphone (the Temporal rep) and the system audio
output (the customer, via a loopback device such as BlackHole), transcribes each
``CHUNK_SECONDS`` window locally with faster-whisper, and pushes each transcribed
segment back to the Workflow as a small ``add_transcript_chunk`` Signal.

It never returns audio or the full transcript (that would exceed the 2 MB payload
limit) -- only a tiny :class:`CaptureResult`.

Stopping:
  * The Workflow cancels this Activity when it receives a ``stop_recording``
    Signal -> we surface ``stop_reason="cancelled"``.
  * ``SILENCE_TIMEOUT_SECONDS`` of continuous silence across both sources ends it
    on its own -> ``stop_reason="silence_timeout"``.
"""

from __future__ import annotations

import asyncio
import threading
from typing import Any, Optional

import numpy as np
from temporalio import activity
from temporalio.exceptions import ApplicationError

from ziggy import config
from ziggy.models import CaptureInput, CaptureResult, Source, TranscriptChunk, default_label

# faster-whisper models are expensive to load; cache per (model, device, compute).
_MODEL_CACHE: dict[tuple[str, str, str], Any] = {}
_MODEL_LOCK = threading.Lock()


def _get_model() -> Any:
    from faster_whisper import WhisperModel  # lazy: avoids import on audio-less hosts

    key = (config.WHISPER_MODEL, config.WHISPER_DEVICE, config.WHISPER_COMPUTE_TYPE)
    with _MODEL_LOCK:
        model = _MODEL_CACHE.get(key)
        if model is None:
            model = WhisperModel(
                config.WHISPER_MODEL,
                device=config.WHISPER_DEVICE,
                compute_type=config.WHISPER_COMPUTE_TYPE,
            )
            _MODEL_CACHE[key] = model
    return model


def _transcribe(model: Any, audio: np.ndarray, language: Optional[str]) -> str:
    segments, _info = model.transcribe(
        audio,
        language=language,
        vad_filter=True,
        beam_size=1,
    )
    return " ".join(seg.text.strip() for seg in segments).strip()


class _Recorder:
    """Opens one sounddevice input stream and accumulates mono float32 frames."""

    def __init__(self, source: Source, device: Optional[str | int], samplerate: int):
        self.source = source
        self.device = device
        self.samplerate = samplerate
        self._frames: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._stream = None

    def _callback(self, indata, frames, time_info, status):  # noqa: ANN001
        # Called from PortAudio's thread. Copy into a mono buffer.
        if status:
            activity.logger.warning("audio status (%s): %s", self.source, status)
        mono = indata[:, 0] if indata.ndim > 1 else indata
        with self._lock:
            self._frames.append(np.asarray(mono, dtype=np.float32).copy())

    def open(self) -> None:
        import sounddevice as sd  # lazy import

        self._stream = sd.InputStream(
            device=self.device,
            channels=1,
            samplerate=self.samplerate,
            dtype="float32",
            callback=self._callback,
        )
        self._stream.start()

    def drain(self) -> np.ndarray:
        with self._lock:
            frames = self._frames
            self._frames = []
        if not frames:
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(frames)

    def close(self) -> None:
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception as exc:  # noqa: BLE001
                activity.logger.warning("error closing stream (%s): %s", self.source, exc)
            self._stream = None


def _rms(audio: np.ndarray) -> float:
    if audio.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(audio))))


@activity.defn(name="capture_audio")
async def capture_audio(input: CaptureInput) -> CaptureResult:
    rate = config.AUDIO_SAMPLE_RATE
    chunk_seconds = config.CHUNK_SECONDS
    silence_timeout = config.SILENCE_TIMEOUT_SECONDS
    rms_threshold = config.SILENCE_RMS_THRESHOLD
    peak_threshold = config.SILENCE_PEAK_THRESHOLD
    language = input.language

    client = activity.client()
    wf_id = activity.info().workflow_id
    handle = client.get_workflow_handle(wf_id)

    # --- open capture devices -------------------------------------------------
    try:
        import sounddevice as sd

        default_in, default_out = sd.default.device
        activity.logger.info(
            "audio config: sample_rate=%d chunk_seconds=%.1f mic_device=%r "
            "system_device=%r default_input=%s",
            rate,
            chunk_seconds,
            config.MIC_DEVICE,
            config.SYSTEM_AUDIO_DEVICE,
            sd.query_devices(default_in)["name"] if default_in is not None else "n/a",
        )
    except Exception as exc:  # noqa: BLE001
        activity.logger.warning("could not query audio devices: %s", exc)

    recorders: list[_Recorder] = []
    mic = _Recorder("mic", config.MIC_DEVICE, rate)
    try:
        mic.open()
        recorders.append(mic)
        activity.logger.info("microphone capture started (mic=Temporal): device=%s", config.MIC_DEVICE)
    except Exception as exc:  # noqa: BLE001
        activity.logger.warning("could not open microphone (%s): %s", config.MIC_DEVICE, exc)

    system = None
    if config.SYSTEM_AUDIO_DEVICE:
        system = _Recorder("output", config.SYSTEM_AUDIO_DEVICE, rate)
        try:
            system.open()
            recorders.append(system)
            activity.logger.info(
                "system-audio capture started (output=Customer): device=%s",
                config.SYSTEM_AUDIO_DEVICE,
            )
        except Exception as exc:  # noqa: BLE001
            activity.logger.warning(
                "could not open system-audio device %r (%s). Customer audio will "
                "NOT be captured. See README for BlackHole setup.",
                config.SYSTEM_AUDIO_DEVICE,
                exc,
            )
            system = None
    else:
        activity.logger.warning(
            "SYSTEM_AUDIO_DEVICE not set; only the microphone (rep) will be captured."
        )

    if not recorders:
        raise ApplicationError(
            "No audio input devices could be opened (mic and system both failed). "
            "Check MIC_DEVICE / SYSTEM_AUDIO_DEVICE and your macOS audio setup.",
            type="NoAudioDevice",
            non_retryable=True,
        )

    model = await asyncio.to_thread(_get_model)

    chunk_index = 0
    total_seconds = 0.0
    silence_elapsed = 0.0
    stop_reason = "unknown"

    try:
        while True:
            # Sleep up to one chunk in small, cancellable steps; heartbeat so the
            # Workflow can cancel us and Temporal knows we're alive.
            waited = 0.0
            step = 0.5
            while waited < chunk_seconds:
                await asyncio.sleep(min(step, chunk_seconds - waited))
                waited += step
                activity.heartbeat(chunk_index)

            window_start = total_seconds
            window_end = total_seconds + chunk_seconds
            total_seconds = window_end

            any_speech = False
            for rec in recorders:
                audio = rec.drain()
                rms = _rms(audio)
                peak = float(np.max(np.abs(audio))) if audio.size else 0.0
                # Speech is bursty: a 20s chunk can have loud words but a low
                # mean RMS. Treat the chunk as having audio if EITHER the peak or
                # the mean RMS clears its bar.
                has_audio = peak >= peak_threshold or rms >= rms_threshold
                activity.logger.info(
                    "chunk %d [%s]: samples=%d (%.1fs) rms=%.4f peak=%.4f "
                    "peak_thr=%.4f rms_thr=%.4f -> %s",
                    chunk_index,
                    rec.source,
                    audio.size,
                    audio.size / rate if rate else 0.0,
                    rms,
                    peak,
                    peak_threshold,
                    rms_threshold,
                    "audio" if has_audio else "silence",
                )
                if audio.size == 0:
                    activity.logger.warning(
                        "[%s] no audio frames captured this chunk -- device may not be "
                        "delivering input (check macOS mic permission / device).",
                        rec.source,
                    )
                    continue
                if not has_audio:
                    activity.logger.info("[%s] below audio thresholds, skipping", rec.source)
                    continue
                text = await asyncio.to_thread(_transcribe, model, audio, language)
                if not text:
                    activity.logger.info(
                        "[%s] audio present but transcriber returned no text (VAD filtered?)",
                        rec.source,
                    )
                    continue
                any_speech = True
                chunk = TranscriptChunk(
                    index=chunk_index,
                    source=rec.source,
                    speaker=default_label(rec.source),
                    text=text,
                    start_seconds=window_start,
                    end_seconds=window_end,
                )
                try:
                    await handle.signal("add_transcript_chunk", chunk)
                    activity.logger.info("[%s] signaled chunk %d: %s", rec.source, chunk_index, text)
                except Exception as exc:  # noqa: BLE001
                    activity.logger.error("failed to signal transcript chunk: %s", exc)
                    raise
                chunk_index += 1

            if any_speech:
                silence_elapsed = 0.0
            else:
                silence_elapsed += chunk_seconds
                if silence_timeout > 0 and silence_elapsed >= silence_timeout:
                    stop_reason = "silence_timeout"
                    activity.logger.info(
                        "stopping after %.0fs of continuous silence", silence_elapsed
                    )
                    break
    except asyncio.CancelledError:
        # A cancellation can mean two very different things:
        #   * worker shutdown (restart / redeploy / crash during graceful stop) --
        #     NOT the end of the meeting. Fail the attempt so Temporal reschedules
        #     capture on a healthy worker and the meeting RESUMES. (Audio during
        #     the gap is lost, but the meeting only ends on stop or silence.)
        #   * a workflow-initiated stop_recording -- finalize normally so the
        #     Workflow receives a CaptureResult and summarizes.
        details = activity.cancellation_details()
        if details is not None and details.worker_shutdown:
            activity.logger.warning(
                "capture cancelled by WORKER SHUTDOWN; failing attempt so it "
                "resumes on restart (meeting not ending)"
            )
            raise ApplicationError(
                "capture interrupted by worker shutdown; resuming",
                type="WorkerShutdown",
            )
        stop_reason = "cancelled"
        activity.logger.info("capture cancelled by workflow (stop_recording)")
    finally:
        for rec in recorders:
            rec.close()

    return CaptureResult(
        chunk_count=chunk_index,
        duration_seconds=total_seconds,
        stop_reason=stop_reason,
        mic_captured=mic in recorders,
        system_captured=system is not None and system in recorders,
    )
