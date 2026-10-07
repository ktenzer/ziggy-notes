"""Provider-agnostic structured LLM completion used by the analysis and summary
Activities.

Supports OpenAI and Anthropic (selected via ``LLM_PROVIDER``). Following the
Temporal AI patterns: provider-side retries are disabled (``max_retries=0``) so
Temporal owns retries, and provider exceptions are translated into
``ApplicationError`` with the right retryable/non-retryable classification.
"""

from __future__ import annotations

import json
from typing import Type, TypeVar

from pydantic import BaseModel
from temporalio.exceptions import ApplicationError

from ziggy import config

T = TypeVar("T", bound=BaseModel)


def resolve_provider() -> str:
    """Pick the LLM provider to use based on configuration AND which API key is
    actually available.

    Preference is ``LLM_PROVIDER``, but if that provider's key is missing we fall
    back to the other provider when its key is present. This makes the app "just
    work" with whichever key the user has set. If NEITHER key is set we raise a
    RETRYABLE error so the activity keeps retrying -- set a key and restart the
    worker and it recovers without failing the workflow.
    """
    pref = (config.LLM_PROVIDER or "openai").strip().lower()
    has_openai = bool(config.OPENAI_API_KEY)
    has_anthropic = bool(config.ANTHROPIC_API_KEY)

    if pref == "anthropic":
        if has_anthropic:
            return "anthropic"
        if has_openai:
            return "openai"
    else:
        if has_openai:
            return "openai"
        if has_anthropic:
            return "anthropic"

    # Retryable (no non_retryable flag) on purpose: see docstring.
    raise ApplicationError(
        "No LLM API key set. Set OPENAI_API_KEY or ANTHROPIC_API_KEY (and "
        "LLM_PROVIDER) in .env and restart the worker; this activity will retry "
        "until a key is available.",
        type="NoLLMKey",
    )


def _classify_openai_error(exc: Exception) -> ApplicationError:
    import openai

    if isinstance(exc, openai.AuthenticationError):
        # Retryable so a fixed key + worker restart recovers without failing the
        # workflow (per unlimited-retry design).
        return ApplicationError(f"OpenAI auth error: {exc}", type="AuthenticationError")
    if isinstance(exc, openai.RateLimitError):
        return ApplicationError(f"OpenAI rate limited: {exc}", type="RateLimitError")
    if isinstance(exc, openai.APIStatusError):
        if exc.status_code >= 500:
            return ApplicationError(f"OpenAI server error {exc.status_code}: {exc}", type="ServerError")
        return ApplicationError(
            f"OpenAI client error {exc.status_code}: {exc}", type="ClientError", non_retryable=True
        )
    if isinstance(exc, openai.APIConnectionError):
        return ApplicationError(f"OpenAI connection error: {exc}", type="ConnectionError")
    return ApplicationError(f"OpenAI error: {exc}", type="LLMError")


def _classify_anthropic_error(exc: Exception) -> ApplicationError:
    import anthropic

    if isinstance(exc, anthropic.AuthenticationError):
        # Retryable so a fixed key + worker restart recovers (see OpenAI note).
        return ApplicationError(f"Anthropic auth error: {exc}", type="AuthenticationError")
    if isinstance(exc, anthropic.RateLimitError):
        return ApplicationError(f"Anthropic rate limited: {exc}", type="RateLimitError")
    if isinstance(exc, anthropic.APIStatusError):
        if exc.status_code >= 500:
            return ApplicationError(f"Anthropic server error {exc.status_code}: {exc}", type="ServerError")
        return ApplicationError(
            f"Anthropic client error {exc.status_code}: {exc}", type="ClientError", non_retryable=True
        )
    if isinstance(exc, anthropic.APIConnectionError):
        return ApplicationError(f"Anthropic connection error: {exc}", type="ConnectionError")
    return ApplicationError(f"Anthropic error: {exc}", type="LLMError")


async def _openai_structured(system_prompt: str, user_prompt: str, response_model: Type[T]) -> T:
    import openai
    from openai import AsyncOpenAI

    if not config.OPENAI_API_KEY:
        raise ApplicationError("OPENAI_API_KEY is not set", type="NoLLMKey")

    client = AsyncOpenAI(api_key=config.OPENAI_API_KEY, max_retries=0, timeout=60.0)
    try:
        completion = await client.beta.chat.completions.parse(
            model=config.llm_model("openai"),
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            response_format=response_model,
            temperature=0.3,
        )
    except Exception as exc:  # noqa: BLE001
        if isinstance(exc, openai.OpenAIError):
            raise _classify_openai_error(exc) from exc
        raise
    parsed = completion.choices[0].message.parsed
    if parsed is None:
        raise ApplicationError("OpenAI returned no parsed structured output", type="LLMError")
    return parsed


async def _anthropic_structured(system_prompt: str, user_prompt: str, response_model: Type[T]) -> T:
    import anthropic
    from anthropic import AsyncAnthropic

    if not config.ANTHROPIC_API_KEY:
        raise ApplicationError("ANTHROPIC_API_KEY is not set", type="NoLLMKey")

    schema = json.dumps(response_model.model_json_schema(), indent=2)
    client = AsyncAnthropic(api_key=config.ANTHROPIC_API_KEY, max_retries=0, timeout=60.0)
    system = (
        f"{system_prompt}\n\nReturn ONLY a single JSON object that validates against "
        f"this JSON schema (no markdown, no prose):\n{schema}"
    )
    try:
        # Note: the Anthropic SDK (>=1.x) no longer accepts a top-level
        # `temperature` kwarg on messages.create, so we omit it (default is fine
        # for structured JSON extraction).
        message = await client.messages.create(
            model=config.llm_model("anthropic"),
            max_tokens=2048,
            system=system,
            messages=[{"role": "user", "content": user_prompt}],
        )
    except Exception as exc:  # noqa: BLE001
        if isinstance(exc, anthropic.AnthropicError):
            raise _classify_anthropic_error(exc) from exc
        raise

    text = "".join(block.text for block in message.content if getattr(block, "type", None) == "text")
    text = text.strip()
    # Be tolerant of accidental ```json fences.
    if text.startswith("```"):
        text = text.strip("`")
        text = text[text.find("{") : text.rfind("}") + 1]
    try:
        return response_model.model_validate_json(text)
    except Exception as exc:  # noqa: BLE001
        raise ApplicationError(
            f"Anthropic returned non-conforming JSON: {exc}", type="LLMError"
        ) from exc


async def structured_completion(system_prompt: str, user_prompt: str, response_model: Type[T]) -> T:
    """Run a structured completion with whichever provider is available."""
    provider = resolve_provider()
    if provider == "anthropic":
        return await _anthropic_structured(system_prompt, user_prompt, response_model)
    return await _openai_structured(system_prompt, user_prompt, response_model)
