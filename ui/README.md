# Ziggy Notes — macOS app

A native SwiftUI client for Ziggy Notes. It connects to Temporal using the
[Apple Swift Temporal SDK](https://github.com/apple/swift-temporal-sdk), runs a
**built-in Swift Temporal worker in-process**, starts/stops meeting workflows,
and polls the workflow for live transcript + active-listening guidance.

The app runs a Swift worker in-process (the sources in [`../worker`](../worker)
compile into the app target) that does everything natively:

- **Audio capture** — microphone via `AVAudioEngine` **and** the meeting's system
  audio via **ScreenCaptureKit**. This works out of the box with **any** output
  device (AirPods, speakers, headsets) — no BlackHole or other loopback driver,
  and nothing for the user to configure.
- **Transcription** — on-device with **WhisperKit** (CoreML Whisper `base`).
- **LLM analysis + summary** — OpenAI or Anthropic.

## Requirements

- macOS 15+
- **Xcode 26.2 or newer** (the Swift Temporal SDK needs Swift 6 and ships a binary
  `BridgeDarwin` xcframework). This project was built with Xcode 27 / Swift 6.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A running Temporal dev server (localhost) **or** Temporal Cloud credentials
- An **OpenAI or Anthropic API key** (set in Settings)

No loopback audio driver is required, and nothing for the user to configure.

## Generate the Xcode project

```bash
cd ui
xcodegen generate
open ZiggyNotes.xcodeproj
```

`project.yml` is the source of truth; re-run `xcodegen generate` after changing it
or adding/removing source files. It compiles `../worker` into the app target
and bundles the role guidance (`ae.md`/`sa.md`/`bdr.md`).

## Build from the command line

The SDK uses a Swift macro and a package trait, so pass `-skipMacroValidation`:

```bash
cd ui
xcodebuild \
  -project ZiggyNotes.xcodeproj \
  -scheme ZiggyNotes \
  -destination 'platform=macOS' \
  -skipMacroValidation \
  build
```

In Xcode, the first build will prompt to **trust & enable** the `TemporalMacros`
and WhisperKit macros — click *Trust*.

## Transcription model (WhisperKit)

By default WhisperKit downloads the `base` CoreML model from Hugging Face on first
launch — seamless, but it needs the network once. To ship it **fully offline**,
pre-bundle it:

```bash
./scripts/fetch-whisper-model.sh base
```

then add `worker/Resources/whisper-models` to `project.yml` as a folder
reference (see [`../worker/Resources/README.md`](../worker/Resources/README.md)).
`Transcriber` prefers the bundled model and only downloads when it is absent.

## Permissions

On launch the app requests:

1. **Microphone** — for `AVAudioEngine` mic capture (the Temporal rep's side).
2. **Screen Recording** — for ScreenCaptureKit system-audio capture (the customer
   side). macOS shows its own prompt the first time; grant it in
   **System Settings → Privacy & Security → Screen Recording** and relaunch if
   prompted.

## Connection configuration (env vars)

| Variable             | Default            | Meaning                                              |
| -------------------- | ------------------ | ---------------------------------------------------- |
| `TEMPORAL_ADDRESS`   | `localhost:7233`   | `host:port` of the Temporal frontend                 |
| `TEMPORAL_NAMESPACE` | `default`          | Namespace                                            |
| `TEMPORAL_TASK_QUEUE`| per-machine        | Auto-derived from the hardware UUID (`ziggy-notes-tq-<tag>`) so users sharing a namespace stay isolated; set only to override |
| `TEMPORAL_API_KEY`   | —                  | If set → **Temporal Cloud** (Bearer auth + TLS)      |
| `TEMPORAL_TLS`       | —                  | `1`/`true`/`yes`/`on` → force TLS for self-hosted    |

With no env vars set, the app connects to a local dev server with plaintext. The
in-process worker and the app's client both use the same per-machine task queue.

## In-app Settings

Open **Settings** (⌘,) to configure the app. These values populate the in-process
worker's `WorkerConfig`, the single source of truth for the running app. Changing
settings restarts the in-process worker.

Required before you can start a note:

| Setting           | Meaning                                                        |
| ----------------- | -------------------------------------------------------------- |
| **Your Role**     | `ae`, `sa`, or `bdr` — tailors live guidance and the summary   |
| **AI Provider**   | OpenAI or Anthropic, plus that provider's API key              |

The role selects a role guidance file bundled with the app
(`ae.md` / `sa.md` / `bdr.md`, sourced from
[`../worker/Resources`](../worker/Resources)) that the worker injects into the
active-listening and summary prompts:

- **Account Executive (`ae`)** — value/business-focused discovery.
- **Solution Architect (`sa`)** — technical; drives a technical win.
- **Business Development Representative (`bdr`)** — non-technical initial call.

There is no default role. If a role (or provider key) is not set, clicking
**New Note** opens Settings instead of starting a note.

Optional:

| Setting             | Meaning                                                                 |
| ------------------- | ---------------------------------------------------------------------- |
| **AI Assistance**   | On (default) surfaces live active-listening guidance during the call. Off: transcribe + summarize only. |

The toggle is captured per-meeting at start time. Every finished note includes a
**Coaching Feedback** card: role-aware feedback plus a **1–10 performance score**.

## In-process worker lifecycle

On launch the app:

1. Requests **microphone** and **screen recording** permission.
2. Starts the in-process Swift worker (`WorkerRuntime`): a `TemporalWorker`
   serving `MeetingWorkflow` + the Ziggy activities, plus a `TemporalClient` the
   capture activity uses to signal transcript chunks. Worker + SDK logs stream
   into the in-app **Worker Logs** view (look for `ziggy worker started`).
3. Connects the app's Temporal client, reconnects to any still-running meetings,
   and begins polling.

Quitting the app stops the worker (graceful client shutdown + task cancellation).

## How it works

- **Start a note** → `startWorkflow(name: "MeetingWorkflow", …)` with a
  `ziggy-meeting-<id>` workflow ID and a `MeetingInput` payload.
- **Capture** → the `capture_audio` activity runs for the whole meeting, chunking
  mic + system audio, transcribing each window with WhisperKit, and signaling
  `add_transcript_chunk` back to the workflow.
- **Live updates** → every few seconds the app runs the `get_updates` query,
  passing the last-seen chunk/suggestion cursors and merging only new rows +
  the current suggestion board. Speaker labels upgrade retroactively as names are
  identified.
- **Stop** → sends the `stop_recording` signal; the app keeps polling until the
  workflow reports completion and surfaces the summary.
- **Guidance** is color-coded by priority: **high = red**, **medium = amber**,
  **low = green**.
- Everything is persisted with **SwiftData**.

## Data compatibility

The Swift worker's domain models ([`../worker/WorkerModels.swift`](../worker/WorkerModels.swift))
and the app's DTOs ([`ZiggyNotes/Models.swift`](ZiggyNotes/Models.swift)) use
explicit snake_case `CodingKeys` for the JSON wire contract carried over the
default data converter. Keep the two in sync.
