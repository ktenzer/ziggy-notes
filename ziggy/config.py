"""Shared configuration and Temporal client connection for Ziggy Notes.

Connection behaviour mirrors the temporal-workflow-throttler example: a single
``connect_temporal_client()`` helper reads environment variables so you can
switch between ``temporal server start-dev`` (localhost) and Temporal Cloud by
changing ENVs only -- no code changes.

On top of the throttler's pattern we also install:
  * the Pydantic data converter (our models are ``pydantic.BaseModel``), and
  * a local-disk External Storage driver so large payloads (full transcript,
    final result) stay under Temporal's 2 MB per-payload limit.
"""

from __future__ import annotations

import dataclasses
import os

from temporalio.client import Client
from temporalio.contrib.pydantic import pydantic_data_converter
from temporalio.converter import ExternalStorage

from ziggy.storage import LocalDiskStorageDriver


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return int(raw)


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return float(raw)


# ---------------------------------------------------------------------------
# Temporal connection
# ---------------------------------------------------------------------------
TEMPORAL_ADDRESS: str = os.environ.get("TEMPORAL_ADDRESS", "localhost:7233")
TEMPORAL_NAMESPACE: str = os.environ.get("TEMPORAL_NAMESPACE", "default")
TEMPORAL_TASK_QUEUE: str = os.environ.get("TEMPORAL_TASK_QUEUE", "ziggy-notes-tq")
TEMPORAL_API_KEY: str | None = os.environ.get("TEMPORAL_API_KEY") or None
TEMPORAL_TLS: bool = _env_bool("TEMPORAL_TLS")

# ---------------------------------------------------------------------------
# External Storage (claim-check)
# ---------------------------------------------------------------------------
EXTERNAL_STORAGE_ENABLED: bool = _env_bool("ZIGGY_EXTERNAL_STORAGE", True)
PAYLOAD_STORE_DIR: str = os.environ.get("ZIGGY_PAYLOAD_STORE_DIR", ".payload-store")
PAYLOAD_THRESHOLD_BYTES: int = _env_int("ZIGGY_PAYLOAD_THRESHOLD_BYTES", 262_144)

# ---------------------------------------------------------------------------
# Audio capture (macOS)
# ---------------------------------------------------------------------------
MIC_DEVICE: str | None = os.environ.get("MIC_DEVICE") or None
SYSTEM_AUDIO_DEVICE: str | None = os.environ.get("SYSTEM_AUDIO_DEVICE") or None
AUDIO_SAMPLE_RATE: int = _env_int("AUDIO_SAMPLE_RATE", 16_000)
CHUNK_SECONDS: float = _env_float("CHUNK_SECONDS", 20.0)
ANALYZE_EVERY_N_CHUNKS: int = _env_int("ANALYZE_EVERY_N_CHUNKS", 3)
SILENCE_TIMEOUT_SECONDS: float = _env_float("SILENCE_TIMEOUT_SECONDS", 300.0)
# A chunk is considered to contain speech if its PEAK amplitude clears this bar
# (speech is bursty, so peak is far more reliable than mean RMS over a long
# chunk) OR its mean RMS clears the RMS bar. Either one triggers transcription.
SILENCE_PEAK_THRESHOLD: float = _env_float("SILENCE_PEAK_THRESHOLD", 0.02)
SILENCE_RMS_THRESHOLD: float = _env_float("SILENCE_RMS_THRESHOLD", 0.005)

# ---------------------------------------------------------------------------
# Transcription (faster-whisper)
# ---------------------------------------------------------------------------
WHISPER_MODEL: str = os.environ.get("WHISPER_MODEL", "base")
WHISPER_DEVICE: str = os.environ.get("WHISPER_DEVICE", "auto")
WHISPER_COMPUTE_TYPE: str = os.environ.get("WHISPER_COMPUTE_TYPE", "int8")

# ---------------------------------------------------------------------------
# LLM
# ---------------------------------------------------------------------------
LLM_PROVIDER: str = os.environ.get("LLM_PROVIDER", "openai").strip().lower()
LLM_MODEL: str | None = os.environ.get("LLM_MODEL") or None
OPENAI_API_KEY: str | None = os.environ.get("OPENAI_API_KEY") or None
ANTHROPIC_API_KEY: str | None = os.environ.get("ANTHROPIC_API_KEY") or None

_DEFAULT_OPENAI_MODEL = "gpt-4o"
_DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-5-5"


def llm_model(provider: str | None = None) -> str:
    if LLM_MODEL:
        return LLM_MODEL
    p = (provider or LLM_PROVIDER).strip().lower()
    return _DEFAULT_ANTHROPIC_MODEL if p == "anthropic" else _DEFAULT_OPENAI_MODEL


# ---------------------------------------------------------------------------
# Workflow Streams / output
# ---------------------------------------------------------------------------
STREAM_DRAIN_SECONDS: float = _env_float("STREAM_DRAIN_SECONDS", 15.0)
OUTPUT_DIR: str = os.environ.get("ZIGGY_OUTPUT_DIR", "out")


def workflow_id_for(meeting_id: str) -> str:
    """Deterministic Workflow Id for a meeting. The capture Activity signals this
    id, and stream subscribers attach to it."""
    return f"ziggy-meeting-{meeting_id}"


def build_data_converter():
    """Pydantic data converter, optionally composed with External Storage."""
    if not EXTERNAL_STORAGE_ENABLED:
        return pydantic_data_converter
    driver = LocalDiskStorageDriver(PAYLOAD_STORE_DIR)
    return dataclasses.replace(
        pydantic_data_converter,
        external_storage=ExternalStorage(
            drivers=[driver],
            payload_size_threshold=PAYLOAD_THRESHOLD_BYTES,
        ),
    )


async def connect_temporal_client() -> Client:
    """Connect to Temporal using the configured environment.

    1. ``TEMPORAL_API_KEY`` set -> Temporal Cloud-style API-key auth with TLS.
    2. ``TEMPORAL_TLS=true`` (no API key) -> system-trust TLS for self-hosted.
    3. Neither set -> plain TCP for ``temporal server start-dev``.
    """
    data_converter = build_data_converter()

    if TEMPORAL_API_KEY:
        return await Client.connect(
            TEMPORAL_ADDRESS,
            namespace=TEMPORAL_NAMESPACE,
            api_key=TEMPORAL_API_KEY,
            tls=True,
            data_converter=data_converter,
        )
    if TEMPORAL_TLS:
        return await Client.connect(
            TEMPORAL_ADDRESS,
            namespace=TEMPORAL_NAMESPACE,
            tls=True,
            data_converter=data_converter,
        )
    return await Client.connect(
        TEMPORAL_ADDRESS,
        namespace=TEMPORAL_NAMESPACE,
        data_converter=data_converter,
    )
