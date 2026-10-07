"""Stop a running Ziggy Notes meeting (stand-in for the future Swift UI).

Sends the ``stop_recording`` Signal, which cancels audio capture and triggers
the summary + Google Doc. Accepts either the full workflow id
(``ziggy-meeting-<id>``) or just the meeting id.

A second stop (or ``--abort``) force-exits: it cancels any in-flight finalize
activity (e.g. a summary LLM call that's failing/retrying) and completes the
workflow immediately with a fallback summary.

Usage:
    uv run python stop.py ziggy-meeting-acme-2026-10-07
    uv run python stop.py acme-2026-10-07
    uv run python stop.py acme-2026-10-07 --abort
"""

from __future__ import annotations

import argparse
import asyncio

from dotenv import load_dotenv

load_dotenv()

from ziggy.config import connect_temporal_client, workflow_id_for  # noqa: E402


async def _stop(workflow_id: str, abort: bool) -> None:
    client = await connect_temporal_client()
    handle = client.get_workflow_handle(workflow_id)
    await handle.signal("abort" if abort else "stop_recording")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("workflow_id", help="Workflow id or meeting id.")
    parser.add_argument(
        "--abort",
        action="store_true",
        help="Force-exit now: cancel in-flight finalize activity and finish.",
    )
    args = parser.parse_args()

    wf_id = args.workflow_id
    if not wf_id.startswith("ziggy-meeting-"):
        wf_id = workflow_id_for(wf_id)

    asyncio.run(_stop(wf_id, args.abort))
    print(f"sent {'abort' if args.abort else 'stop_recording'} signal to {wf_id}")


if __name__ == "__main__":
    main()
