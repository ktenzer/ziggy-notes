"""``analyze_conversation`` -- active-listening analysis Activity.

Given the recent (speaker-labeled) transcript window plus optional call context,
Ziggy (an expert Temporal sales engineer) returns a short list of observations:
things the rep should bring up, features to explain, objections to address, etc.
The Workflow publishes these onto the ``suggestions`` stream topic for the UI.
"""

from __future__ import annotations

from temporalio import activity

from ziggy import config
from ziggy.llm import structured_completion
from ziggy.models import AnalysisInput, AnalysisResult
from ziggy.prompts import analysis_system_prompt, build_analysis_user_prompt


@activity.defn(name="analyze_conversation")
async def analyze_conversation(input: AnalysisInput) -> AnalysisResult:
    user_prompt = build_analysis_user_prompt(
        title=input.title,
        transcript=input.transcript,
        call_context=input.call_context,
        current_suggestions=input.current_suggestions,
        max_suggestions=input.max_suggestions,
    )
    system_prompt = analysis_system_prompt(config.load_role_guidance(config.USER_ROLE))
    result = await structured_completion(
        system_prompt, user_prompt, AnalysisResult
    )
    activity.logger.info(
        "analysis returned %d suggestion(s) for a board of %d",
        len(result.observations),
        len(input.current_suggestions),
    )
    return result
