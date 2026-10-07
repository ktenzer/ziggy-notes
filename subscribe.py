"""Dev subscriber for a Ziggy Notes meeting stream.

Attaches to the meeting's Workflow Stream and prints live transcript lines,
active-listening suggestions, lifecycle changes, and the final summary. This is
a stand-in that proves the exact streaming contract the future Swift UI will
consume (same topics, same typed payloads).

Usage:
    uv run python subscribe.py ziggy-meeting-acme-2026-10-07
    uv run python subscribe.py acme-2026-10-07
"""

from __future__ import annotations

import argparse
import asyncio

from dotenv import load_dotenv
from temporalio.common import RawValue
from temporalio.contrib.workflow_streams import WorkflowStreamClient

load_dotenv()

from ziggy.config import connect_temporal_client, workflow_id_for  # noqa: E402
from ziggy.models import (  # noqa: E402
    TOPIC_LIFECYCLE,
    TOPIC_SPEAKERS,
    TOPIC_SUGGESTIONS,
    TOPIC_SUMMARY,
    TOPIC_TRANSCRIPT,
    LifecycleEvent,
    SpeakerMapEvent,
    SuggestionEvent,
    SummaryEvent,
    TranscriptEvent,
)

_TYPES = {
    TOPIC_TRANSCRIPT: TranscriptEvent,
    TOPIC_SPEAKERS: SpeakerMapEvent,
    TOPIC_SUGGESTIONS: SuggestionEvent,
    TOPIC_SUMMARY: SummaryEvent,
    TOPIC_LIFECYCLE: LifecycleEvent,
}

# Resolved labels learned from SpeakerMapEvent (index -> label). Transcript lines
# arrive before names are known, so we print the best label available at the time
# and announce upgrades as they come in.
_LABELS: dict[int, str] = {}


def _print_transcript(evt: TranscriptEvent) -> None:
    ts = int(evt.start_seconds)
    mm, ss = divmod(ts, 60)
    speaker = _LABELS.get(evt.index, evt.speaker)
    # flush=True so lines appear in real time rather than being buffered.
    print(f"  [{mm:02d}:{ss:02d}] {speaker}: {evt.text}", flush=True)


def _print_speakers(evt: SpeakerMapEvent) -> None:
    _LABELS.update(evt.labels)
    if evt.roster:
        print(f"-- speakers: {', '.join(evt.roster)}", flush=True)


def _print_suggestion(evt: SuggestionEvent) -> None:
    o = evt.observation
    print(f"\n  >> [{o.priority.upper()}] ({o.kind}) {o.title}")
    if o.detail:
        print(f"     {o.detail}")
    print()


def _print_summary(evt: SummaryEvent) -> None:
    s = evt.summary
    print("\n===== SUMMARY =====")
    print(s.summary)
    if s.key_points:
        print("\nKey points:")
        for k in s.key_points:
            print(f"  - {k}")
    if s.action_items:
        print("\nAction items:")
        for a in s.action_items:
            print(f"  - {a}")
    if s.next_steps:
        print("\nNext steps:")
        for n in s.next_steps:
            print(f"  - {n}")
    if evt.google_doc:
        print(f"\nGoogle Doc: {evt.google_doc.url}")
    print("===================\n")


async def _watch(workflow_id: str, transcript_only: bool = False) -> None:
    client = await connect_temporal_client()
    stream = WorkflowStreamClient.create(client, workflow_id=workflow_id)
    converter = client.data_converter.payload_converter

    if transcript_only:
        # Only the transcript topic -- a clean, flowing live transcript for
        # validating that recording/transcription is working.
        print(f"live transcript for {workflow_id} (Ctrl-C to stop)...\n", flush=True)
        async for item in stream.subscribe([TOPIC_TRANSCRIPT], result_type=RawValue):
            evt = converter.from_payload(item.data.payload, TranscriptEvent)
            _print_transcript(evt)
        print("\nstream ended (workflow reached a terminal state).")
        return

    print(f"subscribing to {workflow_id} (Ctrl-C to stop)...\n", flush=True)
    # Subscribe to every topic with a single iterator; dispatch on item.topic.
    async for item in stream.subscribe([], result_type=RawValue):
        model = _TYPES.get(item.topic)
        if model is None:
            continue
        evt = converter.from_payload(item.data.payload, model)
        if item.topic == TOPIC_TRANSCRIPT:
            _print_transcript(evt)
        elif item.topic == TOPIC_SPEAKERS:
            _print_speakers(evt)
        elif item.topic == TOPIC_SUGGESTIONS:
            _print_suggestion(evt)
        elif item.topic == TOPIC_SUMMARY:
            _print_summary(evt)
        elif item.topic == TOPIC_LIFECYCLE:
            print(f"-- {evt.state}" + (f": {evt.detail}" if evt.detail else ""), flush=True)

    print("\nstream ended (workflow reached a terminal state).")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("workflow_id", help="Workflow id or meeting id.")
    parser.add_argument(
        "--transcript-only",
        action="store_true",
        help="Show only the live transcript (no suggestions/summary).",
    )
    args = parser.parse_args()

    wf_id = args.workflow_id
    if not wf_id.startswith("ziggy-meeting-"):
        wf_id = workflow_id_for(wf_id)

    try:
        asyncio.run(_watch(wf_id, transcript_only=args.transcript_only))
    except KeyboardInterrupt:
        print("\nunsubscribed.")


if __name__ == "__main__":
    main()
