"""Repro: stop_recording must terminate the workflow promptly even when an
Activity (analysis and/or summary) is stuck failing + retrying (e.g. LLM 401
with unlimited retries).

Run with a dev server up:
    TEMPORAL_ADDRESS=127.0.0.1:7233 STREAM_DRAIN_SECONDS=1 \
        uv run python tests/stop_during_retry.py
"""

from __future__ import annotations

import asyncio
import time

from temporalio import activity
from temporalio.exceptions import ApplicationError
from temporalio.worker import Worker

from ziggy.config import TEMPORAL_TASK_QUEUE, connect_temporal_client, workflow_id_for
from ziggy.models import (
    AnalysisInput,
    AnalysisResult,
    CaptureInput,
    CaptureResult,
    GoogleDocInput,
    GoogleDocRef,
    IdentityInput,
    IdentityResult,
    MeetingInput,
    MeetingSummary,
    SummaryInput,
    TranscriptChunk,
)
from workflows.meeting import MeetingWorkflow


@activity.defn(name="capture_audio")
async def mock_capture(input: CaptureInput) -> CaptureResult:
    try:
        while True:
            await asyncio.sleep(0.3)
            activity.heartbeat()
    except asyncio.CancelledError:
        return CaptureResult(chunk_count=0, stop_reason="cancelled", mic_captured=True)


@activity.defn(name="analyze_conversation")
async def mock_analyze_always_fails(input: AnalysisInput) -> AnalysisResult:
    # Simulate an LLM auth failure that is RETRYABLE (unlimited retries).
    raise ApplicationError("simulated 401 (retryable)", type="AuthenticationError")


@activity.defn(name="identify_speakers")
async def mock_identify_always_fails(input: IdentityInput) -> IdentityResult:
    raise ApplicationError("simulated 401 (retryable)", type="AuthenticationError")


@activity.defn(name="summarize_meeting")
async def mock_summarize_always_fails(input: SummaryInput) -> MeetingSummary:
    raise ApplicationError("simulated 401 (retryable)", type="AuthenticationError")


@activity.defn(name="create_google_doc")
async def mock_gdoc(input: GoogleDocInput) -> GoogleDocRef:
    return GoogleDocRef(doc_id="stub-1", url="file:///tmp/stub.md", local_path="/tmp/stub.md")


async def main() -> None:
    client = await connect_temporal_client()
    meeting_id = "stop-during-retry"
    wf_id = workflow_id_for(meeting_id)

    worker = Worker(
        client,
        task_queue=TEMPORAL_TASK_QUEUE,
        workflows=[MeetingWorkflow],
        activities=[
            mock_capture,
            mock_analyze_always_fails,
            mock_identify_always_fails,
            mock_summarize_always_fails,
            mock_gdoc,
        ],
    )

    async with worker:
        handle = await client.start_workflow(
            MeetingWorkflow.run,
            MeetingInput(meeting_id=meeting_id, title="Retry repro"),
            id=wf_id,
            task_queue=TEMPORAL_TASK_QUEUE,
        )

        # Feed enough chunks to trigger analysis (ANALYZE_EVERY_N_CHUNKS default 3).
        for i in range(3):
            await handle.signal(
                "add_transcript_chunk",
                TranscriptChunk(
                    index=i,
                    source="mic",
                    text=f"line {i}",
                    start_seconds=float(i * 5),
                    end_seconds=float(i * 5 + 5),
                ),
            )
            await asyncio.sleep(0.1)

        # Let the analysis activity start failing + retrying a couple of times.
        await asyncio.sleep(3)
        status = await handle.query("status")
        print("status while analysis retrying:", status)

        # SINGLE stop, with the summary LLM also down: the workflow must still
        # terminate quickly via the bounded summary window + transcript-only
        # fallback (no second stop / abort here).
        print("sending a SINGLE stop_recording (analysis + summary both failing)...")
        t0 = time.monotonic()
        await handle.signal("stop_recording")

        result = await asyncio.wait_for(handle.result(), timeout=90)
        elapsed = time.monotonic() - t0

    print(f"workflow terminated {elapsed:.1f}s after a single stop")
    print("stop_reason:", result.stop_reason)
    print("summary:", result.summary.summary)
    print("google_doc.doc_id:", result.google_doc.doc_id)
    # Bounded by SUMMARY_SCHEDULE_TO_CLOSE (~40s) + gdoc (~30s) + drain; give margin.
    assert elapsed < 75, f"workflow took too long to stop on a single stop: {elapsed:.1f}s"
    assert "transcript is preserved" in result.summary.summary, result.summary.summary
    print("STOP-DURING-RETRY (single stop) TEST PASSED")


if __name__ == "__main__":
    asyncio.run(main())
