"""``summarize_meeting`` -- final summary Activity.

Produces a concise, high-signal meeting summary (summary, key points, action
items, next steps) from the full transcript, honoring optional user-provided
guidelines and structure. The full transcript may be large; External Storage
offloads it transparently so the Activity input stays under the 2 MB limit.
"""

from __future__ import annotations

from temporalio import activity

from ziggy.llm import structured_completion
from ziggy.models import MeetingSummary, SummaryInput
from ziggy.prompts import SUMMARY_SYSTEM_PROMPT, build_summary_user_prompt


@activity.defn(name="summarize_meeting")
async def summarize_meeting(input: SummaryInput) -> MeetingSummary:
    user_prompt = build_summary_user_prompt(
        title=input.title,
        transcript=input.transcript,
        call_context=input.call_context,
        guidelines=input.guidelines,
        structure=input.structure,
    )
    summary = await structured_completion(
        SUMMARY_SYSTEM_PROMPT, user_prompt, MeetingSummary
    )
    activity.logger.info(
        "summary produced: %d key point(s), %d action item(s), %d next step(s)",
        len(summary.key_points),
        len(summary.action_items),
        len(summary.next_steps),
    )
    return summary
