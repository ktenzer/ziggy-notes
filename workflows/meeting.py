"""``MeetingWorkflow`` -- the durable orchestrator + Workflow Stream host.

Lifecycle:
  1. Starts the long-running ``capture_audio`` Activity (mic + system output).
  2. Receives transcribed chunks as ``add_transcript_chunk`` Signals, appends
     them to its transcript buffer, and re-publishes each onto the ``transcript``
     stream topic for the UI.
  3. Every ``ANALYZE_EVERY_N_CHUNKS`` new chunks, runs ``analyze_conversation``
     and publishes active-listening suggestions onto the ``suggestions`` topic.
  4. Ends when a ``stop_recording`` Signal arrives (UI / stop.py) or when capture
     stops itself after ``SILENCE_TIMEOUT_SECONDS`` of silence.
  5. Summarizes the meeting, writes the (stubbed) Google Doc, publishes the final
     summary, then lingers ``STREAM_DRAIN_SECONDS`` so subscribers drain cleanly.

Design notes on Temporal limits:
  * Each transcript chunk is a small Signal (~1 history event). A typical sales
    call is well within the 50k-event / 50 MB per-execution budget. For
    multi-hour edge cases, Continue-As-New would be added to reset history.
  * The full transcript (summary input + Workflow result) can be large; the
    External Storage driver configured in ``ziggy.config`` offloads it so each
    individual payload stays under the 2 MB limit.
  * The Workflow never reads its own stream (unsupported by design); it keeps its
    own transcript buffer for analysis/summary and uses the stream purely as an
    outbound conduit to subscribers.
"""

from __future__ import annotations

import asyncio
from datetime import timedelta
from typing import Optional

from temporalio import workflow
from temporalio.common import RetryPolicy
from temporalio.contrib.workflow_streams import WorkflowStream
from temporalio.exceptions import ActivityError
from temporalio.exceptions import CancelledError as TemporalCancelledError
from temporalio.workflow import ActivityCancellationType

# Pass these modules through the Workflow sandbox so the classes used inside the
# Workflow are the SAME class objects the Pydantic data converter uses to decode
# Activity results. Without this, the sandbox reimports ziggy.models, creating
# duplicate class identities, and nesting a decoded model (e.g. an Observation
# from an Activity result) inside another model raises a pydantic model_type
# error.
with workflow.unsafe.imports_passed_through():
    from activities.analysis import analyze_conversation
    from activities.capture import capture_audio
    from activities.gdoc import create_google_doc
    from activities.identity import identify_speakers
    from activities.summary import summarize_meeting
    from ziggy import config
    from ziggy.models import (
        TOPIC_LIFECYCLE,
        TOPIC_SPEAKERS,
        TOPIC_SUGGESTIONS,
        TOPIC_SUMMARY,
        TOPIC_TRANSCRIPT,
        AnalysisInput,
        CaptureInput,
        GoogleDocInput,
        GoogleDocRef,
        IdentityInput,
        LifecycleEvent,
        MeetingInput,
        MeetingResult,
        MeetingSummary,
        MeetingUpdates,
        Observation,
        SpeakerMapEvent,
        SuggestionEvent,
        SuggestionRow,
        SummaryEvent,
        SummaryInput,
        TranscriptChunk,
        TranscriptEvent,
        TranscriptRow,
        UpdatesCursor,
        default_label,
    )

# Priority ordering used when trimming the active suggestion board to the cap:
# highs are kept over mediums over lows (then older items are evicted first).
_PRIORITY_RANK = {"high": 0, "medium": 1, "low": 2}

# LLM activities (analysis + summary) retry UNLIMITED (maximum_attempts=0) with
# capped exponential backoff, so a transient LLM error -- or a missing/invalid
# API key that the user fixes and then restarts the worker -- recovers instead
# of failing the whole meeting workflow.
LLM_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=1),
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=30),
    maximum_attempts=0,
)

# The FINAL summary runs AFTER the user stops. Unlike mid-call analysis it must
# NOT retry forever -- the user wants the workflow to terminate. A healthy
# summary is a single quick LLM call; if the LLM is down we retry only a couple
# of times, then fall back to a transcript-only summary and exit. Worst-case
# post-stop latency is bounded by SUMMARY_SCHEDULE_TO_CLOSE below.
SUMMARY_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=1),
    backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=5),
    maximum_attempts=3,
)
SUMMARY_START_TO_CLOSE = timedelta(seconds=30)
SUMMARY_SCHEDULE_TO_CLOSE = timedelta(seconds=40)


@workflow.defn(name="MeetingWorkflow")
class MeetingWorkflow:
    @workflow.init
    def __init__(self, input: MeetingInput) -> None:
        # Workflow Streams must be constructed from @workflow.init (before the
        # first publish Signal can arrive).
        self.stream = WorkflowStream()
        self._transcript_topic = self.stream.topic(TOPIC_TRANSCRIPT, type=TranscriptEvent)
        self._suggestions_topic = self.stream.topic(TOPIC_SUGGESTIONS, type=SuggestionEvent)
        self._summary_topic = self.stream.topic(TOPIC_SUMMARY, type=SummaryEvent)
        self._lifecycle_topic = self.stream.topic(TOPIC_LIFECYCLE, type=LifecycleEvent)
        self._speakers_topic = self.stream.topic(TOPIC_SPEAKERS, type=SpeakerMapEvent)

        self._chunks: list[TranscriptChunk] = []
        self._stop_requested = False
        # A second stop_recording while already stopping escalates to an abort:
        # cancel any in-flight finalize activity (summary/doc) and exit now.
        self._abort_requested = False
        self._last_analyzed_count = 0
        # The live, ranked, capped suggestion board (each item has a stable id).
        # The get_updates Query returns this full set so the UI can reconcile
        # (update/remove) its cards; newly-added items are also published on the
        # suggestions stream topic.
        self._active_suggestions: list[Observation] = []
        # Deterministic, monotonic id source for new suggestions (replay-safe).
        self._next_suggestion_seq = 0
        # Resolved speaker label per chunk index. Starts as the source-based
        # default ("Temporal"/"Customer") and is upgraded to real names by the
        # identify_speakers Activity. _roster is the unique set for the UI.
        self._labels: dict[int, str] = {}
        self._roster: list[str] = []
        self._summary: Optional[MeetingSummary] = None
        self._state = "starting"

    # -- message handlers ----------------------------------------------------
    @workflow.signal(name="add_transcript_chunk")
    async def add_transcript_chunk(self, chunk: TranscriptChunk) -> None:
        # First-activation handler race fix: await a no-op yield once before
        # reading/mutating state (adds no history events).
        await asyncio.sleep(0)
        self._chunks.append(chunk)
        # Seed the resolved label with the source-based default; identify_speakers
        # may upgrade it to a real name later (surfaced via SpeakerMapEvent).
        label = chunk.speaker or default_label(chunk.source)
        self._labels.setdefault(chunk.index, label)
        self._transcript_topic.publish(
            TranscriptEvent(
                index=chunk.index,
                source=chunk.source,
                speaker=self._labels[chunk.index],
                text=chunk.text,
                start_seconds=chunk.start_seconds,
                end_seconds=chunk.end_seconds,
            )
        )

    @workflow.signal(name="stop_recording")
    def stop_recording(self, *_args: object) -> None:
        # First stop = finalize (summarize + exit). A second stop = abort now
        # (cancel any in-flight finalize activity and exit immediately), which
        # matters if the summary LLM call is failing/retrying.
        #
        # ``*_args`` absorbs the stray ``None`` that the community Apple Swift
        # SDK sends for a no-input signal (an empty, encoding-less payload that
        # RobustPydanticPayloadConverter normalizes to ``binary/null`` -> None).
        if self._stop_requested:
            self._abort_requested = True
        self._stop_requested = True

    @workflow.signal(name="abort")
    def abort(self, *_args: object) -> None:
        """Force-exit now: cancel in-flight work and finish without waiting.

        ``*_args`` absorbs the Apple Swift SDK's no-input payload (see
        ``stop_recording``)."""
        self._stop_requested = True
        self._abort_requested = True

    @workflow.query(name="status")
    def status(self) -> dict:
        return {
            "state": self._state,
            "chunk_count": len(self._chunks),
            "stop_requested": self._stop_requested,
            "abort_requested": self._abort_requested,
            "has_summary": self._summary is not None,
            "roster": list(self._roster),
        }

    @workflow.query(name="get_summary")
    def get_summary(self) -> Optional[MeetingSummary]:
        return self._summary

    @workflow.query(name="get_updates")
    def get_updates(self, cursor: Optional[UpdatesCursor] = None) -> MeetingUpdates:
        """Snapshot for the polling UI. Returns transcript rows with index >=
        since_chunk, the FULL current suggestion board (ranked, capped), the full
        current label map/roster, state flags, and the summary once ready."""
        cur = cursor or UpdatesCursor()
        since_chunk = cur.since_chunk
        rows = [
            TranscriptRow(
                index=c.index,
                speaker=self._label_for(c),
                text=c.text,
                start_seconds=c.start_seconds,
                end_seconds=c.end_seconds,
            )
            for c in self._chunks
            if c.index >= since_chunk
        ]
        # The full current board (not cursor-incremental): the client reconciles
        # its displayed cards against this set each poll.
        sugg_rows = [
            SuggestionRow(
                id=o.id,
                kind=o.kind,
                title=o.title,
                detail=o.detail,
                priority=o.priority,
            )
            for o in self._active_suggestions
        ]
        return MeetingUpdates(
            state=self._state,
            stop_requested=self._stop_requested,
            abort_requested=self._abort_requested,
            chunk_count=len(self._chunks),
            suggestion_count=len(self._active_suggestions),
            transcript=rows,
            suggestions=sugg_rows,
            labels=dict(self._labels),
            roster=list(self._roster),
            summary=self._summary,
        )

    # -- helpers -------------------------------------------------------------
    def _label_for(self, chunk: TranscriptChunk) -> str:
        """Resolved display label for a chunk: identified name if we have one,
        else the chunk's own label, else the source-based default."""
        return self._labels.get(chunk.index) or chunk.speaker or default_label(chunk.source)

    def _elapsed_seconds(self) -> float:
        """Elapsed call time, from transcript-chunk timestamps. Used to gate the
        analysis warmup; robust to silence filtering and the two audio sources."""
        return max((c.end_seconds for c in self._chunks), default=0.0)

    def _render_transcript(self, max_chunks: Optional[int] = None) -> str:
        chunks = self._chunks if max_chunks is None else self._chunks[-max_chunks:]
        lines = []
        for c in chunks:
            ts = int(c.start_seconds)
            mm, ss = divmod(ts, 60)
            lines.append(f"[{mm:02d}:{ss:02d}] {self._label_for(c)}: {c.text}")
        return "\n".join(lines)

    def _render_for_identity(self) -> str:
        """Transcript tagged with index + source + timestamp so the LLM can
        attribute each line and return assignments keyed by index."""
        lines = []
        for c in self._chunks:
            ts = int(c.start_seconds)
            mm, ss = divmod(ts, 60)
            lines.append(f"[{c.index}] ({c.source}) [{mm:02d}:{ss:02d}] {c.text}")
        return "\n".join(lines)

    def _apply_identity(self, result) -> None:
        """Merge an IdentityResult into the resolved label map and publish it."""
        changed = False
        valid = {c.index for c in self._chunks}
        for a in result.assignments:
            if a.index in valid and a.label and self._labels.get(a.index) != a.label:
                self._labels[a.index] = a.label
                changed = True
        if result.roster and result.roster != self._roster:
            self._roster = list(result.roster)
            changed = True
        if changed:
            self._speakers_topic.publish(
                SpeakerMapEvent(labels=dict(self._labels), roster=list(self._roster))
            )

    async def _run_identify(
        self,
        input: MeetingInput,
        *,
        retry_policy: RetryPolicy,
        start_to_close: timedelta,
        schedule_to_close: Optional[timedelta] = None,
        watch_abort: bool = False,
    ) -> None:
        """Attribute transcript lines to speakers (names from introductions),
        updating the resolved label map. Best-effort: never fails the meeting.

        Cancellable: during the live meeting it's interrupted by stop; the final
        pre-summary pass is interrupted only by an abort (so a single stop still
        gets names in the summary, bounded by schedule_to_close)."""
        transcript = self._render_for_identity()
        if not transcript.strip():
            return
        act = workflow.start_activity(
            identify_speakers,
            IdentityInput(
                title=input.title,
                transcript=transcript,
                call_context=input.call_context,
                rep_name=input.rep_name,
            ),
            start_to_close_timeout=start_to_close,
            schedule_to_close_timeout=schedule_to_close,
            retry_policy=retry_policy,
            cancellation_type=ActivityCancellationType.TRY_CANCEL,
        )
        flag = (lambda: self._abort_requested) if watch_abort else (lambda: self._stop_requested)
        await workflow.wait_condition(lambda: act.done() or flag())
        if not act.done():
            act.cancel()
            try:
                await act
            except Exception:  # noqa: BLE001
                pass
            return
        try:
            result = await act
        except Exception as exc:  # noqa: BLE001
            workflow.logger.warning("identify_speakers failed, keeping current labels: %s", exc)
            return
        self._apply_identity(result)

    async def _run_analysis(self, input: MeetingInput) -> None:
        self._last_analyzed_count = len(self._chunks)
        # Send the FULL cumulative transcript so far (chunks 1..N), not just a
        # trailing window: each analysis pass sees everything said up to this
        # point, so when 5 new chunks arrive after the first 10 we send all 15,
        # then all 20, and so on. prior_observation_titles still prevents the
        # model from repeating suggestions it already surfaced.
        transcript = self._render_transcript()
        if not transcript.strip():
            return
        self._state = "analyzing"
        # Run analysis as a cancellable child activity and race it against the
        # stop flag. The activity retries unlimited (LLM resilience), but a
        # stop_recording signal must interrupt it immediately instead of waiting
        # for a possibly-forever-retrying LLM call.
        act = workflow.start_activity(
            analyze_conversation,
            AnalysisInput(
                title=input.title,
                transcript=transcript,
                call_context=input.call_context,
                current_suggestions=list(self._active_suggestions),
                max_suggestions=config.MAX_ACTIVE_SUGGESTIONS,
            ),
            start_to_close_timeout=timedelta(seconds=90),
            retry_policy=LLM_RETRY,
            cancellation_type=ActivityCancellationType.TRY_CANCEL,
        )
        await workflow.wait_condition(lambda: act.done() or self._stop_requested)
        if not act.done():
            act.cancel()
            try:
                await act
            except Exception:  # noqa: BLE001
                pass
            self._state = "recording"
            return
        try:
            result = await act
        except Exception as exc:  # noqa: BLE001
            workflow.logger.warning("analysis activity failed, skipping: %s", exc)
            self._state = "recording"
            return
        self._apply_suggestions(result.observations)
        self._state = "recording"

    def _new_sid(self) -> str:
        """Deterministic, monotonic suggestion id (replay-safe)."""
        sid = f"s{self._next_suggestion_seq}"
        self._next_suggestion_seq += 1
        return sid

    def _apply_suggestions(self, desired: list[Observation]) -> None:
        """Replace the board with the model's desired set: keep items whose id
        matches an existing one (reusing the id), assign ids to new ones, then
        rank by priority (then order) and trim to MAX_ACTIVE_SUGGESTIONS.

        Publishes a SuggestionEvent on the stream only for newly-added ids;
        removals are reflected via the get_updates Query."""
        existing_ids = {o.id for o in self._active_suggestions if o.id}
        merged: list[Observation] = []
        new_ids: list[str] = []
        for obs in desired:
            if obs.id and obs.id in existing_ids:
                oid = obs.id
            else:
                oid = self._new_sid()
                new_ids.append(oid)
            merged.append(
                Observation(
                    id=oid,
                    kind=obs.kind,
                    title=obs.title,
                    detail=obs.detail,
                    priority=obs.priority,
                )
            )
        # Rank high->medium->low, keeping the model's order within a priority as a
        # recency tiebreak, then enforce the cap (evict lower priority / older).
        ranked = sorted(
            enumerate(merged),
            key=lambda t: (_PRIORITY_RANK.get(t[1].priority, 1), t[0]),
        )
        trimmed = [o for _, o in ranked[: config.MAX_ACTIVE_SUGGESTIONS]]
        kept_ids = {o.id for o in trimmed}
        self._active_suggestions = trimmed
        for o in trimmed:
            if o.id in new_ids and o.id in kept_ids:
                self._suggestions_topic.publish(
                    SuggestionEvent(at_chunk=len(self._chunks), observation=o)
                )

    async def _finish_or_abort(self, act, fallback):
        """Await a finalize activity, but cancel it immediately if an abort is
        requested. Returns the activity result, or ``fallback(aborted)`` on abort
        or failure, so the workflow always exits."""
        await workflow.wait_condition(lambda: act.done() or self._abort_requested)
        if not act.done():
            act.cancel()
            try:
                await act
            except Exception:  # noqa: BLE001
                pass
            return fallback(True)
        try:
            return await act
        except Exception as exc:  # noqa: BLE001
            workflow.logger.warning("finalize activity failed, using fallback: %s", exc)
            return fallback(False)

    # -- entrypoint ----------------------------------------------------------
    @workflow.run
    async def run(self, input: MeetingInput) -> MeetingResult:
        self._state = "recording"
        self._lifecycle_topic.publish(LifecycleEvent(state="recording", detail=input.title))

        capture = workflow.start_activity(
            capture_audio,
            CaptureInput(meeting_id=input.meeting_id, language=input.language),
            start_to_close_timeout=timedelta(hours=8),
            heartbeat_timeout=timedelta(seconds=30),
            # Capture must RESUME across worker restarts/crashes, not end the
            # meeting. Unlimited retries: a worker-shutdown failure (or a
            # heartbeat timeout from a hard crash) reschedules capture on a
            # healthy worker. The meeting only finalizes on a stop_recording
            # Signal (capture returns "cancelled") or the silence timeout
            # (capture returns "silence_timeout"). A non-retryable NoAudioDevice
            # error still ends it.
            retry_policy=RetryPolicy(
                initial_interval=timedelta(seconds=1),
                backoff_coefficient=2.0,
                maximum_interval=timedelta(seconds=30),
                maximum_attempts=0,
            ),
            cancellation_type=ActivityCancellationType.TRY_CANCEL,
        )

        # Orchestration loop: wake on stop, capture completion, or enough new
        # chunks to analyze.
        while True:
            if not input.ai_assistance:
                # AI assistance off: transcript-only mode. We still receive and
                # publish transcript chunks (via the add_transcript_chunk Signal
                # handler), but run NO live analysis/identify. Just wait until the
                # user stops or capture ends, then finalize + summarize.
                await workflow.wait_condition(
                    lambda: self._stop_requested or capture.done()
                )
                break
            await workflow.wait_condition(
                lambda: self._stop_requested
                or capture.done()
                or (len(self._chunks) - self._last_analyzed_count) >= config.ANALYZE_EVERY_N_CHUNKS
            )
            if self._stop_requested or capture.done():
                break
            # Warmup: surface no live guidance until enough elapsed call time has
            # passed. Reset the cadence counter so we re-check after N more chunks
            # instead of busy-looping.
            if self._elapsed_seconds() < config.ANALYSIS_WARMUP_MINUTES * 60:
                self._last_analyzed_count = len(self._chunks)
                continue
            # Attribute speakers first (so live suggestions use names), then
            # analyze. Both are stop-cancellable and best-effort.
            await self._run_identify(
                input, retry_policy=LLM_RETRY, start_to_close=timedelta(seconds=60)
            )
            await self._run_analysis(input)

        stop_reason = "stopped" if self._stop_requested else "capture_ended"
        if not capture.done():
            capture.cancel()
        try:
            capture_result = await capture
            stop_reason = capture_result.stop_reason
        except (asyncio.CancelledError, TemporalCancelledError, ActivityError):
            # Expected when we cancel capture in response to stop_recording.
            workflow.logger.info("capture stopped by workflow (stop_recording)")
        except Exception as exc:  # noqa: BLE001
            workflow.logger.warning("capture activity ended with error: %s", exc)
            stop_reason = "capture_error"

        # Analyze any trailing chunks that didn't hit the cadence -- but skip
        # this when the user asked to stop: they want to finalize and exit, not
        # kick off another LLM round. Also skipped entirely when AI assistance
        # is off (transcript-only mode).
        if (
            input.ai_assistance
            and not self._stop_requested
            and len(self._chunks) > self._last_analyzed_count
            and self._elapsed_seconds() >= config.ANALYSIS_WARMUP_MINUTES * 60
        ):
            await self._run_analysis(input)

        # Final speaker attribution so the summary and saved transcript use real
        # names where known. Bounded + abort-cancellable so a stop still exits
        # promptly even if the LLM is down (we just keep the current labels).
        await self._run_identify(
            input,
            retry_policy=SUMMARY_RETRY,
            start_to_close=SUMMARY_START_TO_CLOSE,
            schedule_to_close=SUMMARY_SCHEDULE_TO_CLOSE,
            watch_abort=True,
        )

        # --- summarize --------------------------------------------------------
        self._state = "summarizing"
        self._lifecycle_topic.publish(LifecycleEvent(state="summarizing", detail=stop_reason))
        transcript = self._render_transcript()

        # The summary runs after stop, so it is tightly bounded: a single stop
        # terminates the workflow within ~SUMMARY_SCHEDULE_TO_CLOSE even if the
        # LLM is down (few bounded retries, then transcript-only fallback). A
        # second stop / the abort signal cancels it immediately via _finish_or_abort.
        summary_act = workflow.start_activity(
            summarize_meeting,
            SummaryInput(
                title=input.title,
                transcript=transcript,
                call_context=input.call_context,
                guidelines=input.summary_guidelines,
                structure=input.summary_structure,
            ),
            start_to_close_timeout=SUMMARY_START_TO_CLOSE,
            schedule_to_close_timeout=SUMMARY_SCHEDULE_TO_CLOSE,
            retry_policy=SUMMARY_RETRY,
            cancellation_type=ActivityCancellationType.TRY_CANCEL,
        )
        summary = await self._finish_or_abort(
            summary_act,
            fallback=lambda aborted: MeetingSummary(
                summary=(
                    "Summary aborted by user; full transcript is preserved."
                    if aborted
                    else "Summary unavailable (LLM error); full transcript is preserved."
                )
            ),
        )
        self._summary = summary
        self._summary_topic.publish(SummaryEvent(summary=summary))

        # --- Google Doc (stubbed) --------------------------------------------
        if self._abort_requested:
            google_doc = GoogleDocRef(doc_id="aborted", url="", local_path=None)
        else:
            gdoc_act = workflow.start_activity(
                create_google_doc,
                GoogleDocInput(
                    meeting_id=input.meeting_id,
                    title=input.title,
                    summary=summary,
                    transcript=transcript,
                ),
                start_to_close_timeout=timedelta(seconds=20),
                schedule_to_close_timeout=timedelta(seconds=30),
                retry_policy=RetryPolicy(maximum_attempts=3),
                cancellation_type=ActivityCancellationType.TRY_CANCEL,
            )
            google_doc = await self._finish_or_abort(
                gdoc_act,
                fallback=lambda _aborted: GoogleDocRef(
                    doc_id="unavailable", url="", local_path=None
                ),
            )
        self._summary_topic.publish(SummaryEvent(summary=summary, google_doc=google_doc))

        self._state = "completed"
        self._lifecycle_topic.publish(LifecycleEvent(state="completed", detail=stop_reason))

        # Stream drain overlap: linger so late/slow subscribers receive the final
        # events before the Workflow reaches a terminal state.
        await workflow.sleep(timedelta(seconds=config.STREAM_DRAIN_SECONDS))

        return MeetingResult(
            meeting_id=input.meeting_id,
            title=input.title,
            chunk_count=len(self._chunks),
            stop_reason=stop_reason,
            transcript=transcript,
            summary=summary,
            google_doc=google_doc,
            roster=list(self._roster),
        )
