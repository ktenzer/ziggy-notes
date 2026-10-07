"""End-to-end smoke test for MeetingWorkflow against a running dev server.

Uses MOCK activities (no audio devices, no LLM keys) so it validates the
orchestration, Signals, Workflow Streams publishing, and the summary/Google Doc
path deterministically.

Run with a dev server up:
    TEMPORAL_ADDRESS=127.0.0.1:7233 STREAM_DRAIN_SECONDS=1 \
        uv run python tests/smoke_e2e.py
"""

from __future__ import annotations

import asyncio

from temporalio import activity
from temporalio.common import RawValue
from temporalio.contrib.workflow_streams import WorkflowStreamClient
from temporalio.worker import Worker

from ziggy.config import (
    TEMPORAL_TASK_QUEUE,
    connect_temporal_client,
    workflow_id_for,
)
from ziggy.models import (
    TOPIC_SPEAKERS,
    TOPIC_SUGGESTIONS,
    TOPIC_SUMMARY,
    TOPIC_TRANSCRIPT,
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
    Observation,
    SpeakerAssignment,
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
async def mock_analyze(input: AnalysisInput) -> AnalysisResult:
    return AnalysisResult(
        observations=[
            Observation(
                kind="explain_feature",
                title="Explain durable execution",
                detail="Customer worried about lost state on crash.",
                priority="high",
            )
        ]
    )


@activity.defn(name="identify_speakers")
async def mock_identify(input: IdentityInput) -> IdentityResult:
    # Attribute mic lines to a Temporal rep and output lines to a customer, as if
    # they had introduced themselves.
    assignments = []
    roster: list[str] = []
    for raw in input.transcript.splitlines():
        # lines look like: "[<index>] (<source>) [mm:ss] text"
        if not raw.startswith("["):
            continue
        idx = int(raw[1 : raw.index("]")])
        src = "mic" if "(mic)" in raw else "output"
        label = "John (Temporal)" if src == "mic" else "Sarah (Customer)"
        assignments.append(SpeakerAssignment(index=idx, label=label, name=label.split()[0], org="temporal" if src == "mic" else "customer"))
        if label not in roster:
            roster.append(label)
    return IdentityResult(assignments=assignments, roster=roster)


@activity.defn(name="summarize_meeting")
async def mock_summarize(input: SummaryInput) -> MeetingSummary:
    return MeetingSummary(
        summary="Acme is evaluating Temporal for order orchestration.",
        key_points=["Current cron+retries brittle"],
        action_items=["Share durable-execution one-pager"],
        next_steps=["Schedule technical deep-dive"],
    )


@activity.defn(name="create_google_doc")
async def mock_gdoc(input: GoogleDocInput) -> GoogleDocRef:
    return GoogleDocRef(doc_id="stub-1", url="file:///tmp/stub.md", local_path="/tmp/stub.md")


async def main() -> None:
    client = await connect_temporal_client()
    meeting_id = "smoke-test"
    wf_id = workflow_id_for(meeting_id)

    worker = Worker(
        client,
        task_queue=TEMPORAL_TASK_QUEUE,
        workflows=[MeetingWorkflow],
        activities=[mock_capture, mock_analyze, mock_identify, mock_summarize, mock_gdoc],
    )

    collected: dict[str, int] = {"transcript": 0, "speakers": 0, "suggestions": 0, "summary": 0}

    async with worker:
        handle = await client.start_workflow(
            MeetingWorkflow.run,
            MeetingInput(meeting_id=meeting_id, title="Acme discovery call"),
            id=wf_id,
            task_queue=TEMPORAL_TASK_QUEUE,
        )

        # Subscribe to the stream concurrently (what the Swift UI will do).
        stream = WorkflowStreamClient.create(client, workflow_id=wf_id)

        async def consume() -> None:
            try:
                async for item in stream.subscribe([], result_type=RawValue):
                    if item.topic in collected:
                        collected[item.topic] += 1
            except Exception:  # noqa: BLE001
                # A poll Update in flight when the workflow completes surfaces as
                # an error; expected per the Workflow Streams docs.
                pass

        consumer = asyncio.create_task(consume())

        # Simulate the capture activity pushing transcript chunks.
        await asyncio.sleep(1)
        for i in range(4):
            source = "output" if i % 2 else "mic"
            await handle.signal(
                "add_transcript_chunk",
                TranscriptChunk(
                    index=i,
                    source=source,
                    text=f"line {i}",
                    start_seconds=float(i * 5),
                    end_seconds=float(i * 5 + 5),
                ),
            )
            await asyncio.sleep(0.2)

        # Let analysis run, then stop the meeting.
        await asyncio.sleep(2)
        status = await handle.query("status")
        print("status before stop:", status)

        await handle.signal("stop_recording")

        result = await handle.result()
        try:
            await asyncio.wait_for(consumer, timeout=10)
        except asyncio.TimeoutError:
            consumer.cancel()

    # ---- assertions --------------------------------------------------------
    # A stop_recording signal cancels capture, so awaiting it raises and the
    # reason stays "stopped" (silence-timeout is the path that returns a value).
    assert result.chunk_count == 4, result.chunk_count
    assert result.stop_reason == "stopped", result.stop_reason
    assert "Acme" in result.summary.summary
    assert result.summary.next_steps
    assert result.google_doc.doc_id == "stub-1"
    assert "line 0" in result.transcript
    # Speaker attribution: mic -> "John (Temporal)", output -> "Sarah (Customer)".
    assert "John (Temporal):" in result.transcript, result.transcript
    assert "Sarah (Customer):" in result.transcript, result.transcript
    assert "John (Temporal)" in result.roster and "Sarah (Customer)" in result.roster, result.roster
    assert collected["transcript"] == 4, collected
    assert collected["speakers"] >= 1, collected
    assert collected["suggestions"] >= 1, collected
    assert collected["summary"] >= 1, collected

    print("transcript (rendered):")
    print(result.transcript)
    print("stream event counts:", collected)
    print("SMOKE TEST PASSED")


if __name__ == "__main__":
    asyncio.run(main())
