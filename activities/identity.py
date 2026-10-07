"""``identify_speakers`` -- speaker attribution Activity.

Given the cumulative transcript (each line tagged with its index, audio source,
and timestamp), an LLM attributes each line to a speaker using self-introductions
and conversational cues, returning a per-line label plus a roster. The Workflow
applies these labels (upgrading "Temporal"/"Customer" to real names where found)
and publishes them on the ``speakers`` stream topic.

This never fabricates names: when a speaker never identifies themselves it falls
back to the source-based side label ("Temporal" for the mic, "Customer" for the
call's audio output).
"""

from __future__ import annotations

from temporalio import activity

from ziggy.llm import structured_completion
from ziggy.models import IdentityInput, IdentityResult
from ziggy.prompts import IDENTITY_SYSTEM_PROMPT, build_identity_user_prompt


@activity.defn(name="identify_speakers")
async def identify_speakers(input: IdentityInput) -> IdentityResult:
    user_prompt = build_identity_user_prompt(
        title=input.title,
        transcript=input.transcript,
        call_context=input.call_context,
        rep_name=input.rep_name,
    )
    result = await structured_completion(
        IDENTITY_SYSTEM_PROMPT, user_prompt, IdentityResult
    )
    activity.logger.info(
        "identify_speakers: %d assignment(s), roster=%s",
        len(result.assignments),
        result.roster,
    )
    return result
