"""``create_google_doc`` -- STUBBED Google Doc creation Activity.

For now this writes a local Markdown file under ``ZIGGY_OUTPUT_DIR`` and returns
a :class:`GoogleDocRef` pointing at it. The real Google Docs integration (Docs
API via a service account or OAuth) is intentionally isolated to THIS file so it
can be swapped in without touching the Workflow or any other code.

TODO(real integration): replace ``_write_local_markdown`` with a Google Docs API
call:
  1. Authenticate (service account JSON or OAuth user flow).
  2. ``documents.create`` to make the doc, then ``documents.batchUpdate`` to
     insert the formatted summary + transcript.
  3. Optionally share via the Drive API and return the real ``webViewLink``.
Keep returning a ``GoogleDocRef`` so the rest of the system is unchanged.
"""

from __future__ import annotations

import os

from temporalio import activity

from ziggy import config
from ziggy.models import GoogleDocInput, GoogleDocRef, MeetingSummary


def _render_markdown(title: str, summary: MeetingSummary, transcript: str) -> str:
    def _bullets(items: list[str]) -> str:
        return "\n".join(f"- {item}" for item in items) if items else "_None_"

    return f"""# {title}

## Summary

{summary.summary or "_No summary produced._"}

## Key Points

{_bullets(summary.key_points)}

## Action Items

{_bullets(summary.action_items)}

## Next Steps

{_bullets(summary.next_steps)}

---

## Full Transcript

{transcript or "_No transcript captured._"}
"""


@activity.defn(name="create_google_doc")
async def create_google_doc(input: GoogleDocInput) -> GoogleDocRef:
    os.makedirs(config.OUTPUT_DIR, exist_ok=True)
    filename = f"{input.meeting_id}.md"
    path = os.path.abspath(os.path.join(config.OUTPUT_DIR, filename))
    content = _render_markdown(input.title, input.summary, input.transcript)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)

    activity.logger.info("wrote meeting doc (Google Doc stub) to %s", path)

    # STUB: a real integration would return the Google Docs webViewLink here.
    doc_id = f"stub-{input.meeting_id}"
    return GoogleDocRef(
        doc_id=doc_id,
        url=f"file://{path}",
        local_path=path,
    )
