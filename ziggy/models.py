"""Shared data models for Ziggy Notes.

All models subclass ``pydantic.BaseModel`` so they serialize cleanly through the
``pydantic_data_converter`` configured in :mod:`ziggy.config`. These types are
used as Workflow/Activity inputs and results *and* as Workflow Stream event
payloads, so a future Swift UI has a single, typed contract to consume.
"""

from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field

# The ground-truth AUDIO SOURCE a transcript chunk came from. This is always
# known with certainty (it's which device captured the audio):
#   * "mic"    -> the local microphone = the Temporal rep's side.
#   * "output" -> the system audio output (remote participants), captured via a
#                 loopback device such as BlackHole.
Source = Literal["mic", "output"]

# Which organization a speaker belongs to, once we can tell (from introductions
# or provided context). "unknown" until/unless we can attribute it.
Org = Literal["temporal", "customer", "unknown"]


def default_label(source: Source) -> str:
    """Fallback display label when we don't (yet) know a speaker's name.

    This encodes the user's desired fallback: the microphone is always the
    Temporal rep, and anything from the call's audio output is, when in doubt,
    the Customer.
    """
    return "Temporal" if source == "mic" else "Customer"


# ---------------------------------------------------------------------------
# Workflow input / result
# ---------------------------------------------------------------------------
class MeetingInput(BaseModel):
    """Input to ``MeetingWorkflow``."""

    meeting_id: str
    title: str = "Temporal Sales Call"
    # Placeholder for now: situational context about THIS call (account, stage,
    # attendees, goals). Will later be produced by another workflow/process and
    # passed in here. See ziggy/context/temporal_sales_context.md.
    call_context: Optional[str] = None
    # Optional known name of the Temporal rep on the mic. If set, mic lines are
    # attributed to this person instead of the generic "Temporal" label. If not
    # set, we still fall back to "Temporal" for the mic.
    rep_name: Optional[str] = None
    # Optional user guidance for the final summary.
    summary_guidelines: Optional[str] = None
    summary_structure: Optional[str] = None
    # Optional forced transcription language (e.g. "en"). None = autodetect.
    language: Optional[str] = None
    # When False, skip live active-listening analysis (no suggestions surfaced
    # during the call). The call is still transcribed and summarized. Captured at
    # workflow start so a running meeting is deterministic regardless of later
    # env/UI changes. Defaults to True (full assistance).
    ai_assistance: bool = True


class TranscriptChunk(BaseModel):
    """One transcribed segment of audio from a single audio source.

    Sent from the capture Activity to the Workflow as a (small) Signal and
    re-published by the Workflow onto the ``transcript`` stream topic.

    ``source`` is ground truth (which device captured it). ``speaker`` is the
    resolved display label -- it starts as the source-based default
    ("Temporal"/"Customer") and is upgraded to a real name once the
    ``identify_speakers`` Activity attributes it from introductions.
    """

    index: int
    source: Source
    speaker: str = ""
    text: str
    start_seconds: float = 0.0
    end_seconds: float = 0.0


class CaptureInput(BaseModel):
    """Input to the ``capture_audio`` Activity. Device/chunking settings are read
    from the environment inside the Activity; only per-meeting values live here.
    The Workflow Id to signal is inferred from the Activity context."""

    meeting_id: str
    language: Optional[str] = None


class CaptureResult(BaseModel):
    """Small summary returned by the capture Activity (never the audio or the
    full transcript -- those would blow the 2 MB payload limit)."""

    chunk_count: int = 0
    duration_seconds: float = 0.0
    # "silence_timeout" | "cancelled" | "error"
    stop_reason: str = "unknown"
    mic_captured: bool = False
    system_captured: bool = False


# ---------------------------------------------------------------------------
# Active-listening analysis
# ---------------------------------------------------------------------------
class Observation(BaseModel):
    """A single active-listening suggestion for the rep."""

    # Stable id for this suggestion across analysis passes. Empty means "new" --
    # the workflow assigns an id. The LLM reuses an existing id for any suggestion
    # it keeps, so the UI can update/remove the right card.
    id: str = ""
    # bring_up | explain_feature | address_objection | answer_question |
    # risk | next_step
    kind: str = "bring_up"
    title: str
    detail: str = ""
    priority: Literal["high", "medium", "low"] = "medium"


class AnalysisInput(BaseModel):
    """Input to the ``analyze_conversation`` Activity."""

    title: str
    transcript: str
    call_context: Optional[str] = None
    # The suggestions currently displayed (with ids), so the LLM can keep the
    # still-relevant ones (reusing their id), drop any that were addressed or
    # became irrelevant, add new ones, and re-rank -- returning the full set.
    current_suggestions: list[Observation] = Field(default_factory=list)
    # Hard cap on how many suggestions should be active at once.
    max_suggestions: int = 5


class AnalysisResult(BaseModel):
    # The FULL desired active set for this pass (kept items reuse their id).
    observations: list[Observation] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Speaker identification (name/role attribution from introductions)
# ---------------------------------------------------------------------------
class SpeakerAssignment(BaseModel):
    """The resolved speaker for one transcript line (by chunk index)."""

    index: int
    # Final display label, e.g. "John (Temporal)", "Sarah (Customer)", "Temporal",
    # or "Customer". Always non-empty (falls back to the source-based default).
    label: str
    # Best-known real name, or None if the speaker never identified themselves.
    name: Optional[str] = None
    org: Org = "unknown"


class IdentityInput(BaseModel):
    """Input to the ``identify_speakers`` Activity."""

    title: str
    # Transcript rendered with per-line index + source + timestamp, so the LLM
    # can attribute each line and return assignments keyed by index.
    transcript: str
    call_context: Optional[str] = None
    rep_name: Optional[str] = None


class IdentityResult(BaseModel):
    assignments: list[SpeakerAssignment] = Field(default_factory=list)
    # Unique people discovered so far, as display labels (for a roster/UI).
    roster: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Final summary + Google Doc
# ---------------------------------------------------------------------------
class SummaryInput(BaseModel):
    """Input to the ``summarize_meeting`` Activity."""

    title: str
    transcript: str
    call_context: Optional[str] = None
    guidelines: Optional[str] = None
    structure: Optional[str] = None


class MeetingSummary(BaseModel):
    summary: str = ""
    key_points: list[str] = Field(default_factory=list)
    action_items: list[str] = Field(default_factory=list)
    next_steps: list[str] = Field(default_factory=list)
    # Role-aware coaching: honest, constructive feedback on how the user performed
    # on this call and what they could have done better.
    feedback: str = Field(
        default="",
        description=(
            "Brief (2-4 sentences) honest, constructive feedback on how well the "
            "user (the Temporal side) performed their role on this call, and "
            "specifically what they could have done better. Empty if there is not "
            "enough conversation to judge."
        ),
    )
    # Performance score 1 (poor) .. 10 (excellent), judged against the user's role
    # objectives. 0 means not scored (insufficient conversation).
    score: int = Field(
        default=0,
        description=(
            "Overall performance score from 1 (poor) to 10 (excellent) rating how "
            "well the user accomplished their role's objectives on this call. "
            "Reserve 9-10 for truly excellent calls. Use 0 only when there is not "
            "enough conversation to judge."
        ),
    )


class GoogleDocInput(BaseModel):
    meeting_id: str
    title: str
    summary: MeetingSummary
    transcript: str


class GoogleDocRef(BaseModel):
    doc_id: str
    url: str
    # Local filesystem path while the Google Docs integration is stubbed.
    local_path: Optional[str] = None


class MeetingResult(BaseModel):
    """Final Workflow result. ``transcript`` may be large; External Storage
    offloads it transparently so the payload stays under 2 MB."""

    meeting_id: str
    title: str
    chunk_count: int
    stop_reason: str
    transcript: str
    summary: MeetingSummary
    google_doc: GoogleDocRef
    # Unique speakers identified during the call (display labels).
    roster: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Incremental polling snapshot (consumed by the macOS UI via the get_updates
# Query). Kept small/bounded so the payload never trips the External Storage
# claim-check -- clients that can't resolve offloaded payloads (e.g. the Swift
# SDK) therefore always get inline, decodable JSON.
# ---------------------------------------------------------------------------
class TranscriptRow(BaseModel):
    index: int
    speaker: str
    text: str
    start_seconds: float = 0.0
    end_seconds: float = 0.0


class SuggestionRow(BaseModel):
    # Stable id (matches the Observation id) so the UI can reconcile the active
    # set across polls (update/remove the right card).
    id: str = ""
    at_chunk: int = 0
    kind: str = "bring_up"
    title: str
    detail: str = ""
    priority: Literal["high", "medium", "low"] = "medium"


class UpdatesCursor(BaseModel):
    """Client's last-seen position, passed to the ``get_updates`` Query so the
    Workflow only returns new transcript rows / suggestions. Sent as a single
    argument (parameter-pack-friendly for the Swift client)."""

    since_chunk: int = 0
    since_suggestion: int = 0


class MeetingUpdates(BaseModel):
    """Snapshot returned by the ``get_updates`` Query. ``transcript`` contains
    only rows at/after the client's last-seen index. ``suggestions`` is the FULL
    current active set (ranked, capped) -- clients reconcile (update/remove) their
    displayed cards against it rather than appending. ``labels`` is the full
    current index->label map so the client can retroactively upgrade earlier
    transcript rows as names are identified."""

    state: str
    stop_requested: bool = False
    abort_requested: bool = False
    chunk_count: int = 0
    suggestion_count: int = 0
    transcript: list[TranscriptRow] = Field(default_factory=list)
    suggestions: list[SuggestionRow] = Field(default_factory=list)
    labels: dict[int, str] = Field(default_factory=dict)
    roster: list[str] = Field(default_factory=list)
    summary: Optional[MeetingSummary] = None


# ---------------------------------------------------------------------------
# Workflow Stream event payloads (one type per topic)
# ---------------------------------------------------------------------------
TOPIC_TRANSCRIPT = "transcript"
TOPIC_SUGGESTIONS = "suggestions"
TOPIC_SUMMARY = "summary"
TOPIC_LIFECYCLE = "lifecycle"
TOPIC_SPEAKERS = "speakers"


class TranscriptEvent(BaseModel):
    index: int
    source: Source
    # Resolved display label at publish time (source-based default initially;
    # upgraded later via SpeakerMapEvent as names are identified).
    speaker: str
    text: str
    start_seconds: float = 0.0
    end_seconds: float = 0.0


class SpeakerMapEvent(BaseModel):
    """Published whenever speaker attribution is (re)computed. Carries the full
    current index -> label map so a subscriber can retroactively upgrade earlier
    transcript lines (e.g. "Customer" -> "Sarah (Customer)") and render a roster.
    """

    labels: dict[int, str] = Field(default_factory=dict)
    roster: list[str] = Field(default_factory=list)


class SuggestionEvent(BaseModel):
    at_chunk: int
    observation: Observation


class SummaryEvent(BaseModel):
    summary: MeetingSummary
    google_doc: Optional[GoogleDocRef] = None


class LifecycleEvent(BaseModel):
    # recording | analyzing | summarizing | completed | error
    state: str
    detail: str = ""
