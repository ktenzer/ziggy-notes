# Ziggy Notes — macOS app

A native SwiftUI client for Ziggy Notes. It connects to Temporal using the
community-supported [Apple Swift Temporal SDK](https://github.com/apple/swift-temporal-sdk),
starts the Python worker for you, starts/stops meeting workflows, and polls the
workflow for live transcript + active-listening guidance.

The app is a thin control/visualization layer. **All audio capture, transcription,
and LLM work stays in the Python worker** (`../worker.py`) — the app just launches
it and talks to the same Temporal workflow via start / signal / query.

## Requirements

- macOS 15+
- **Xcode 26.2 or newer** (the Swift Temporal SDK needs Swift 6 and ships a binary
  `BridgeDarwin` xcframework). This project was built with Xcode 27 / Swift 6.4.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [uv](https://docs.astral.sh/uv/) on your `PATH` (the app runs `uv run python worker.py`)
- A running Temporal dev server (localhost) **or** Temporal Cloud credentials
- BlackHole (or similar loopback) configured for system-audio capture, as used by
  the Python worker

## Generate the Xcode project

```bash
cd ui
xcodegen generate
open ZiggyNotes.xcodeproj
```

`project.yml` is the source of truth; re-run `xcodegen generate` after changing it
or adding files.

## Build from the command line

The SDK uses a Swift macro and a package trait, so pass `-skipMacroValidation`:

```bash
cd ui
xcodebuild \
  -project ZiggyNotes.xcodeproj \
  -scheme ZiggyNotes \
  -destination 'platform=macOS,arch=arm64' \
  -skipMacroValidation \
  build
```

In Xcode, the first build will prompt to **trust & enable** the `TemporalMacros`
macro — click *Trust*.

## Connection configuration (env vars)

Mirrors the Python `ziggy/config.py` logic exactly:

| Variable             | Default            | Meaning                                              |
| -------------------- | ------------------ | ---------------------------------------------------- |
| `TEMPORAL_ADDRESS`   | `localhost:7233`   | `host:port` of the Temporal frontend                 |
| `TEMPORAL_NAMESPACE` | `default`          | Namespace                                            |
| `TEMPORAL_TASK_QUEUE`| per-machine        | Auto-derived from the hardware UUID (`ziggy-notes-tq-<tag>`) so users sharing a namespace stay isolated; set only to override |
| `TEMPORAL_API_KEY`   | —                  | If set → **Temporal Cloud** (Bearer auth + TLS)      |
| `TEMPORAL_TLS`       | —                  | `1`/`true`/`yes`/`on` → force TLS for self-hosted    |

With no env vars set, the app connects to a local dev server with plaintext.

Set these in the **scheme's Run → Environment Variables** when launching from Xcode,
or export them before launching the built app from a terminal.

## In-app Settings

Open **Settings** (⌘,) to configure the app. These values are written through to
the project's `.env` and injected into the worker process, then the worker is
restarted so changes take effect.

Required before you can start a note:

| Setting           | `.env` key                         | Meaning                                                        |
| ----------------- | ---------------------------------- | -------------------------------------------------------------- |
| **Your Role**     | `USER_ROLE`                        | `ae`, `sa`, or `bdr` — tailors live guidance and the summary   |
| **AI Provider**   | `LLM_PROVIDER` + `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | Provider and its API key                   |

`USER_ROLE` selects an English "skill" file under
[`ziggy/roles/`](../ziggy/roles) (`ae.md` / `sa.md` / `bdr.md`) that the worker
injects into the active-listening and summary prompts:

- **Account Executive (`ae`)** — value/business-focused discovery (use case,
  stakeholders, blockers, timeline, scale, business value for Temporal Cloud).
- **Solution Architect (`sa`)** — technical; drives a technical win and
  unblocks the use case into production by positioning Temporal's features.
- **Business Development Representative (`bdr`)** — non-technical initial call;
  piques interest and books a follow-up with the AE + SA.

There is no default role. If a role (or provider key) is not set, clicking
**New Note** opens Settings instead of starting a note.

Optional:

| Setting             | `.env` key            | Meaning                                                                 |
| ------------------- | --------------------- | ---------------------------------------------------------------------- |
| **AI Assistance**   | `ZIGGY_AI_ASSISTANCE` | On (default) surfaces live active-listening guidance during the call. Off: the call is only transcribed and summarized — no live suggestions. |

The toggle is captured per-meeting at start time, so changing it only affects
notes started afterward. Regardless of the toggle, every finished note includes a
**Coaching Feedback** card: brief, role-aware feedback on what you could have done
better plus a **1–10 performance score** judged against your role's objectives
(see the `## Feedback and scoring` section in each `ziggy/roles/*.md`).

## Worker auto-start

On launch the app:

1. Requests **microphone** permission (the spawned worker's mic access is attributed
   to this app, so you only grant it once here).
2. Starts the Python worker by launching the project's venv interpreter directly
   (`<project>/.venv/bin/python worker.py`) and waits for the `ziggy worker started`
   log line. The app only proceeds if startup succeeds; otherwise it shows the worker
   output and a **Retry** button. Launching the interpreter directly (instead of
   `uv run`) means the app supervises the worker process itself.

   > Prerequisite: run `uv sync` in the project directory once so `.venv` exists.

**Lifecycle:** quitting the app (or closing its window) stops the worker — it is sent
SIGTERM for a graceful shutdown, then SIGKILL if it doesn't exit promptly. No orphaned
worker is left running.
3. Connects the Temporal client and reconnects to any meetings that were still
   running, then begins polling.

### Project directory resolution

The app needs to know where `worker.py` lives. It resolves, in order:

1. `ziggyProjectDir` in `UserDefaults`
2. `ZIGGY_PROJECT_DIR` environment variable
3. Auto-detection by walking up from the app bundle
4. Fallback: `~/temporal/ziggy-notes`

## How it works

- **Start a note** → `startWorkflow(name: "MeetingWorkflow", …)` with a
  `ziggy-meeting-<id>` workflow ID and a `MeetingInput` payload.
- **Live updates** → every **10 seconds** (the workflow task timeout) the app runs the
  `get_updates` query, passing the last-seen chunk/suggestion cursors and merging only
  new transcript rows + suggestions into local storage. Speaker labels are upgraded
  retroactively as names are identified.
- **Stop** → sends the `stop_recording` signal; the app keeps polling until the
  workflow reports completion and surfaces the summary.
- **Guidance** is color-coded by priority: **high = red**, **medium = amber**,
  **low = green**.
- Everything is persisted with **SwiftData**, so meetings (and their guidance) survive
  relaunches, and running meetings are resumed automatically.

## Data compatibility

Swift `Codable` DTOs in `Models.swift` use explicit snake_case `CodingKeys` to match
the Python/pydantic field names, so payloads round-trip between the two SDKs over the
default JSON data converter. Keep these in sync with `../ziggy/models.py` (notably
`MeetingInput`, `MeetingUpdates`, `TranscriptRow`, `SuggestionRow`, `MeetingSummary`).
