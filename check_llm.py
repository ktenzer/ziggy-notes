"""Quick LLM API-key / config check for Ziggy Notes.

Loads your .env, resolves the provider exactly like the app does, and makes one
minimal live call so you can confirm the key + model work before starting a
meeting.

Usage:
    uv run python check_llm.py
"""

from __future__ import annotations

import asyncio

from dotenv import load_dotenv

load_dotenv(dotenv_path=".env")

from ziggy import config  # noqa: E402
from ziggy.llm import resolve_provider  # noqa: E402


def _mask(key: str | None) -> str:
    if not key:
        return "(not set)"
    if len(key) <= 12:
        return key[:4] + "..."
    return f"{key[:10]}...{key[-4:]} (len={len(key)})"


async def _check_openai() -> None:
    from openai import AsyncOpenAI

    model = config.llm_model("openai")
    print(f"provider=openai model={model} key={_mask(config.OPENAI_API_KEY)}")
    client = AsyncOpenAI(api_key=config.OPENAI_API_KEY, max_retries=0, timeout=30.0)
    resp = await client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": "Reply with the single word: pong"}],
        max_tokens=5,
    )
    print("response:", resp.choices[0].message.content)


async def _check_anthropic() -> None:
    from anthropic import AsyncAnthropic

    model = config.llm_model("anthropic")
    print(f"provider=anthropic model={model} key={_mask(config.ANTHROPIC_API_KEY)}")
    client = AsyncAnthropic(api_key=config.ANTHROPIC_API_KEY, max_retries=0, timeout=30.0)
    msg = await client.messages.create(
        model=model,
        max_tokens=16,
        messages=[{"role": "user", "content": "Reply with the single word: pong"}],
    )
    text = "".join(b.text for b in msg.content if getattr(b, "type", None) == "text")
    print("response:", text.strip())


async def _main() -> int:
    print(
        f"LLM_PROVIDER={config.LLM_PROVIDER!r} "
        f"OPENAI_API_KEY={_mask(config.OPENAI_API_KEY)} "
        f"ANTHROPIC_API_KEY={_mask(config.ANTHROPIC_API_KEY)}"
    )
    try:
        provider = resolve_provider()
    except Exception as exc:  # noqa: BLE001
        print(f"\nFAIL: {exc}")
        return 1

    print(f"resolved provider -> {provider}\n")
    try:
        if provider == "anthropic":
            await _check_anthropic()
        else:
            await _check_openai()
    except Exception as exc:  # noqa: BLE001
        status = getattr(exc, "status_code", None)
        print(f"\nFAIL ({type(exc).__name__}"
              f"{f', HTTP {status}' if status else ''}): {exc}")
        if status == 401:
            print(
                "\n-> 401 means the key is rejected. Anthropic Messages API keys "
                "start with 'sk-ant-api03-'; a 'sk-ant-usr-' token won't work. "
                "Get a key at https://console.anthropic.com/settings/keys"
            )
        return 1

    print("\nOK: API key and model are working.")
    return 0


def main() -> None:
    raise SystemExit(asyncio.run(_main()))


if __name__ == "__main__":
    main()
