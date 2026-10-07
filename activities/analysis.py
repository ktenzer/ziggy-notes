"""``analyze_conversation`` -- active-listening analysis Activity.

Given the recent (speaker-labeled) transcript window plus optional call context,
Ziggy (an expert Temporal sales engineer) returns a short list of observations:
things the rep should bring up, features to explain, objections to address, etc.
The Workflow publishes these onto the ``suggestions`` stream topic for the UI.
"""

from __future__ import annotations

from temporalio import activity

from ziggy.llm import structured_completion
from ziggy.models import AnalysisInput, AnalysisResult
from ziggy.prompts import TEMPORAL_SALES_SYSTEM_PROMPT, build_analysis_user_prompt


@activity.defn(name="analyze_conversation")
async def analyze_conversation(input: AnalysisInput) -> AnalysisResult:
    user_prompt = build_analysis_user_prompt(
        title=input.title,
        transcript=input.transcript,
        call_context=input.call_context,
        prior_observation_titles=input.prior_observation_titles,
    )
    result = await structured_completion(
        TEMPORAL_SALES_SYSTEM_PROMPT, user_prompt, AnalysisResult
    )
    activity.logger.info("analysis produced %d observation(s)", len(result.observations))
    return result
