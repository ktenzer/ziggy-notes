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
import hashlib
import os
import subprocess

from functools import lru_cache
from pathlib import Path
from typing import Any, Sequence

import temporalio.api.common.v1
from temporalio.client import Client
from temporalio.contrib.pydantic import PydanticPayloadConverter, pydantic_data_converter
from temporalio.converter import ExternalStorage

from ziggy.storage import LocalDiskStorageDriver


class RobustPydanticPayloadConverter(PydanticPayloadConverter):
    """Pydantic payload converter that tolerates payloads with no ``encoding``.

    The community Apple Swift SDK encodes a no-input Signal/Query as a single
    empty ``Payload`` with *no* metadata (in particular, no ``encoding`` key)
    rather than the standard ``binary/null`` payload. The stock converter raises
    ``KeyError: Unknown payload encoding <unknown>`` on such a payload, which
    makes the worker silently *drop* the signal -- so e.g. ``stop_recording``
    sent from the Swift app never reaches the workflow.

    We normalize any encoding-less payload to ``binary/null`` (which decodes to
    ``None``) before delegating to the stock converter. The ``None`` is absorbed
    by the ``*args`` on our no-argument Signal handlers.
    """

    def from_payloads(
        self,
        payloads: Sequence[temporalio.api.common.v1.Payload],
        type_hints: list[type] | None = None,
    ) -> list[Any]:
        normalized = [self._normalize(p) for p in payloads]
        return super().from_payloads(normalized, type_hints)

    @staticmethod
    def _normalize(
        payload: temporalio.api.common.v1.Payload,
    ) -> temporalio.api.common.v1.Payload:
        if b"encoding" in payload.metadata:
            return payload
        # No encoding metadata (Apple SDK's empty Void payload). Treat it as the
        # canonical "null" payload so it decodes to None instead of blowing up.
        return temporalio.api.common.v1.Payload(metadata={"encoding": b"binary/null"})


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


def _hardware_uuid() -> str | None:
    """This Mac's hardware UUID (IOPlatformUUID), via ``ioreg``. None if unavailable."""
    try:
        out = subprocess.run(
            ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if "IOPlatformUUID" in line:
            # e.g.   "IOPlatformUUID" = "C1234567-89AB-CDEF-0123-456789ABCDEF"
            parts = line.split('"')
            if len(parts) >= 4:
                return parts[3]
    return None


def _device_task_queue() -> str:
    """Per-machine task queue so users sharing a namespace never pick up each
    other's work (and a workflow is only run by the worker on the machine that
    captured its audio). Derived from the hardware UUID; matches the Swift app's
    ``TemporalConfig.deviceTaskQueue`` (SHA-256 of the UUID, first 12 hex chars).
    Normally the app injects ``TEMPORAL_TASK_QUEUE`` into the worker, so this is
    only computed for standalone/CLI use."""
    base = _hardware_uuid()
    if not base:
        return "ziggy-notes-tq"
    tag = hashlib.sha256(base.encode("utf-8")).hexdigest()[:12]
    return f"ziggy-notes-tq-{tag}"


# Prefer an explicit env value (the macOS app always injects one); otherwise
# derive a machine-unique queue so manual worker/CLI runs stay isolated too.
TEMPORAL_TASK_QUEUE: str = os.environ.get("TEMPORAL_TASK_QUEUE") or _device_task_queue()
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
# AI assistance (live active-listening analysis)
# ---------------------------------------------------------------------------
# When enabled (default), the workflow runs live analysis during the call and
# surfaces active-listening suggestions. When disabled, the call is only
# transcribed and summarized -- no live guidance. Toggled from the UI (written to
# .env as ZIGGY_AI_ASSISTANCE) and used as the default for newly started
# meetings; the actual value is captured per-meeting in ``MeetingInput`` so a
# running workflow is unaffected by later env changes.
AI_ASSISTANCE_ENABLED: bool = _env_bool("ZIGGY_AI_ASSISTANCE", True)

# Don't surface any live guidance until the conversation has warmed up: no
# active-listening analysis runs until this many minutes of ELAPSED call time
# have passed (measured from transcript-chunk timestamps, so it's robust to
# silence filtering and the two audio sources). After warmup, the normal
# every-ANALYZE_EVERY_N_CHUNKS cadence applies.
ANALYSIS_WARMUP_MINUTES: float = _env_float("ANALYSIS_WARMUP_MINUTES", 5.0)

# Cap on how many live suggestions are shown at once. Each analysis pass returns
# the full desired set; the workflow trims to this many, evicting lower-priority
# (and then older) items first.
MAX_ACTIVE_SUGGESTIONS: int = _env_int("MAX_ACTIVE_SUGGESTIONS", 5)


# ---------------------------------------------------------------------------
# User role (AE / SA / BDR)
# ---------------------------------------------------------------------------
# The person running the app picks a role in the UI (written to .env as
# USER_ROLE). It selects an English "skill" file under ziggy/roles/ that is
# injected into the live-analysis and summary system prompts so guidance matches
# how that role sells. Unset/invalid falls back to the base prompt.
USER_ROLE: str | None = (os.environ.get("USER_ROLE") or "").strip().lower() or None
VALID_ROLES: set[str] = {"ae", "sa", "bdr"}
ROLES_DIR: Path = Path(__file__).parent / "roles"


@lru_cache(maxsize=None)
def load_role_guidance(role: str | None) -> str | None:
    """Return the English behavior guidance for ``role`` (``ae``/``sa``/``bdr``).

    Reads ``ziggy/roles/<role>.md`` (resolved relative to this package, so it
    works regardless of the worker's cwd). Returns ``None`` when the role is
    unset, unknown, or the file is missing/empty -- callers then use the base
    prompt unchanged.
    """
    if not role or role not in VALID_ROLES:
        return None
    path = ROLES_DIR / f"{role}.md"
    try:
        return path.read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


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
    """Pydantic data converter, optionally composed with External Storage.

    Uses :class:`RobustPydanticPayloadConverter` so no-input signals sent by the
    community Apple Swift SDK (empty, encoding-less payloads) are not dropped.
    """
    base = dataclasses.replace(
        pydantic_data_converter,
        payload_converter_class=RobustPydanticPayloadConverter,
    )
    if not EXTERNAL_STORAGE_ENABLED:
        return base
    driver = LocalDiskStorageDriver(PAYLOAD_STORE_DIR)
    return dataclasses.replace(
        base,
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
