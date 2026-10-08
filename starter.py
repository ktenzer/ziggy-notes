"""Start a Ziggy Notes meeting-recording workflow.

Usage:
    uv run python starter.py --title "Acme discovery call"
    uv run python starter.py --meeting-id acme-2026-10-07 \
        --context-file ziggy/context/temporal_sales_context.md
    uv run python starter.py --title "Acme" --guidelines "Focus on technical wins"

Starting the workflow begins audio recording on the worker machine. Stop it with
``stop.py`` (or, eventually, the Swift UI) or let it auto-stop on silence.
"""

from __future__ import annotations

import argparse
import asyncio
import uuid
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

from ziggy.config import (  # noqa: E402
    AI_ASSISTANCE_ENABLED,
    TEMPORAL_TASK_QUEUE,
    connect_temporal_client,
    workflow_id_for,
)
from ziggy.models import MeetingInput  # noqa: E402
from workflows.meeting import MeetingWorkflow  # noqa: E402


def _read_optional(path: str | None) -> str | None:
    if not path:
        return None
    return Path(path).read_text(encoding="utf-8")


async def _start(args: argparse.Namespace) -> str:
    client = await connect_temporal_client()

    meeting_id = args.meeting_id or f"{uuid.uuid4().hex[:8]}"
    wf_id = workflow_id_for(meeting_id)

    meeting_input = MeetingInput(
        meeting_id=meeting_id,
        title=args.title,
        call_context=_read_optional(args.context_file),
        summary_guidelines=args.guidelines,
        summary_structure=_read_optional(args.structure_file),
        language=args.language,
        rep_name=args.rep_name,
        ai_assistance=not args.no_ai_assistance,
    )

    await client.start_workflow(
        MeetingWorkflow.run,
        meeting_input,
        id=wf_id,
        task_queue=TEMPORAL_TASK_QUEUE,
    )
    return wf_id


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--meeting-id", help="Stable id for this meeting (default: random).")
    parser.add_argument("--title", default="Temporal Sales Call")
    parser.add_argument("--context-file", help="Path to a call-context markdown file.")
    parser.add_argument("--guidelines", help="Optional free-text summary guidelines.")
    parser.add_argument("--structure-file", help="Path to a desired summary-structure file.")
    parser.add_argument("--language", help="Force transcription language (e.g. 'en').")
    parser.add_argument(
        "--rep-name",
        help="Name of the Temporal rep on the mic (attributes mic lines to them).",
    )
    parser.add_argument(
        "--no-ai-assistance",
        action="store_true",
        default=not AI_ASSISTANCE_ENABLED,
        help=(
            "Disable live active-listening analysis (no suggestions). The call is "
            "still transcribed and summarized. Defaults to the ZIGGY_AI_ASSISTANCE "
            "env setting."
        ),
    )
    args = parser.parse_args()

    wf_id = asyncio.run(_start(args))
    print(f"started meeting workflow: {wf_id}")
    print("recording has begun on the worker machine.")
    print(f"  watch live:  uv run python subscribe.py {wf_id}")
    print(f"  stop:        uv run python stop.py {wf_id}")


if __name__ == "__main__":
    main()
