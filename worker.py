"""Ziggy Notes worker.

Registers ``MeetingWorkflow`` and all Activities on the configured task queue.
The capture Activity records real-time audio, so run the worker on the macOS
machine that has the microphone + loopback (BlackHole) devices.
"""

from __future__ import annotations

import asyncio
import logging
import signal

from dotenv import load_dotenv
from temporalio.worker import Worker

load_dotenv()

from activities import ALL_ACTIVITIES  # noqa: E402
from ziggy.config import (  # noqa: E402
    TEMPORAL_ADDRESS,
    TEMPORAL_API_KEY,
    TEMPORAL_NAMESPACE,
    TEMPORAL_TASK_QUEUE,
    connect_temporal_client,
)
from workflows.meeting import MeetingWorkflow  # noqa: E402


async def _run_worker() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s %(message)s",
    )
    logger = logging.getLogger("ziggy.worker")

    client = await connect_temporal_client()

    worker = Worker(
        client,
        task_queue=TEMPORAL_TASK_QUEUE,
        workflows=[MeetingWorkflow],
        activities=ALL_ACTIVITIES,
    )

    logger.info(
        "ziggy worker started: address=%s namespace=%s task_queue=%s auth=%s",
        TEMPORAL_ADDRESS,
        TEMPORAL_NAMESPACE,
        TEMPORAL_TASK_QUEUE,
        "api-key" if TEMPORAL_API_KEY else "none",
    )

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    async with worker:
        await stop_event.wait()
        logger.info("shutting down ziggy worker")


def main() -> None:
    asyncio.run(_run_worker())


if __name__ == "__main__":
    main()
