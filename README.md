# Ziggy Listens

**An active-listening meeting note-taker for Temporal sales calls, built on Temporal.**

Ziggy is a Temporal-native take on [Abridge](https://www.abridge.com/) — the
tool that listens to a doctor/patient visit and, in real time, surfaces
suggestions and then writes up a structured summary. Ziggy does the same for
**Temporal sales conversations**: it records the call, transcribes it live,
and acts as an expert Temporal sales engineer whispering in your ear — "bring
this up", "explain Continue-As-New here", "that's an objection, answer it like
this" — then produces a concise summary + next steps when the meeting ends.

It is used by Temporal and built on Temporal.

Ziggy ships as a **native macOS app** (`ui/`) with a **Swift Temporal worker that
runs in-process** (`worker/`). Everything — audio capture, transcription, LLM
analysis, and the durable orchestration — runs inside the app. There is no
separate backend to deploy and nothing for the user to configure.

## How it works

```
app ─ start ─▶ MeetingWorkflow ─ get_updates query (polled) ─▶ app UI
app ─ signal ─▶   │  (keeps transcript + ranked suggestion board)
                  │
                  ├─▶ capture_audio (long-running Activity)
                  │     mic (AVAudioEngine) = You
                  │     system audio (ScreenCaptureKit) = Other
                  │     WhisperKit per chunk ─ signals each chunk back ▲
                  │
                  ├─▶ analyze_conversation (every N chunks, LLM) ─▶ suggestions
                  └─▶ summarize_meeting (identifies attendees) + create_google_doc (on stop/silence)
```

- **One durable `MeetingWorkflow` per meeting** orchestrates everything and keeps
  its own transcript buffer for analysis and the final summary. The app polls the
  `get_updates` query for live transcript + suggestions (no Workflow Streams — the
  app is the only consumer).
- **`capture_audio`** is a single long-running, heartbeating Activity so there are
  no gaps in the recording. It captures the microphone (you, the rep) via
  `AVAudioEngine` **and** the meeting's system audio (the remote side) via
  **ScreenCaptureKit** — no loopback driver like BlackHole, and nothing to
  configure; it works with AirPods or any output device. Each `CHUNK_SECONDS`
  window is transcribed on-device with **WhisperKit** and pushed back to the
  workflow as a small `add_transcript_chunk` Signal. If the worker restarts
  mid-meeting, capture is **rescheduled and resumes** (it distinguishes a worker
  shutdown from a `stop_recording`), so the meeting only ends on a stop Signal or
  the silence timeout — never because the worker bounced.
- **`analyze_conversation`** runs every few chunks (once the conversation has
  warmed up for `ANALYSIS_WARMUP_MINUTES` of elapsed call time) and maintains a
  live, ranked board of at most `MAX_ACTIVE_SUGGESTIONS`: each pass returns the
  full desired set so applied/irrelevant advice is dropped, new advice is added,
  and items are re-prioritized.
- On a `stop_recording` signal or `SILENCE_TIMEOUT_SECONDS` of silence, the
  workflow runs **`summarize_meeting`** and **`create_google_doc`**, then returns
  the full transcript + summary + doc link.

## Speaker identification

Who-said-what is resolved by **audio source**, and attendees are named **once at
the end** as part of summarization:

1. **Live transcript (by source).** Every transcript chunk is tagged with its
   source: the **mic** is always you (labeled **"You"**) and the **system audio
   output** is the remote side (labeled **"Other"**). The live transcript keeps
   these labels throughout the call — there is no per-chunk relabeling.
2. **Attendees (at the end).** `summarize_meeting` makes a single LLM call that,
   in addition to the summary, returns an **`attendees`** list. It extracts names
   from self-introductions ("my name is John", "this is Sarah from Acme") and the
   call context, tags them with "(Temporal)"/"(Customer)" where the side is clear,
   and includes you by name (taken from the rep name you entered when starting the
   note, or the local macOS account's full name). The attendees are shown at the
   top of the finished summary.

**Limitation:** the live transcript only separates *sides* (You vs Other); it does
not tell apart multiple distinct remote voices sharing one channel. True per-voice
separation would require audio diarization, which can be added later as another
activity without changing this contract.

## Roles

Your sales **role** tailors the live guidance and the summary. It selects a role
guidance file bundled with the app (`worker/Resources/ae.md` / `sa.md` / `bdr.md`)
that the worker injects into the active-listening and summary prompts:

- **Account Executive (`ae`)** — value/business-focused discovery (use case,
  stakeholders, blockers, timeline, scale, business value for Temporal Cloud).
- **Solution Architect (`sa`)** — technical; drives a technical win and unblocks
  the use case into production by positioning Temporal's features.
- **Business Development Representative (`bdr`)** — non-technical initial call;
  piques interest and books a follow-up with the AE + SA.

Every finished note also includes a **Coaching Feedback** card: brief, role-aware
feedback on what you could have done better, plus a **1–10 performance score**
judged against your role's objectives (see the `## Feedback and scoring` section
in each role file).

## Build & run

Prerequisites: macOS 15+, Xcode 26.2+ (Swift 6), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). You
also need a reachable Temporal (a local `temporal server start-dev`, or Temporal
Cloud credentials) and an OpenAI or Anthropic API key (set in the app's Settings).

```bash
cd ziggy-notes
./build_dmg.sh            # Release build (for sharing), packages a DMG
# or ./build_dmg.sh Debug
```

The script runs `xcodegen generate` and `xcodebuild` for the project under `ui/`,
ad-hoc signs the app, then writes a drag-to-install `~/Documents/ZiggyListens.dmg`
containing **Ziggy Listens.app**, an Applications symlink, and a `READ ME FIRST.txt`.
Open it and drag the app to Applications.

**Sharing with testers:** the DMG is ad-hoc signed (so it launches on any Apple
Silicon Mac) but **not notarized** — Apple notarization needs the paid Apple
Developer Program. On first launch testers get a Gatekeeper prompt; they clear it
once via **System Settings → Privacy & Security → Open Anyway** (the right-click →
Open shortcut no longer works on macOS Sequoia). The bundled `READ ME FIRST.txt`
spells out that step plus the Microphone / Screen-Recording grants and Settings
(role, API key, Temporal endpoint).

To develop in Xcode instead:

```bash
cd ui
xcodegen generate
open ZiggyNotes.xcodeproj
```

On first launch, grant **Microphone** and **Screen Recording** permission (the
latter is what makes hands-off system-audio capture work). Then open **Settings**
(⌘,), pick your role and AI provider/key, and click **New Note**.

See [`ui/README.md`](ui/README.md) for the full app docs (connection settings,
permissions, the WhisperKit model, and how start/stop/poll work).

## Transcription model

Transcription is on-device and offline via **WhisperKit** (`base` CoreML model).
By default the model downloads once on first launch; to ship it fully offline,
run `./scripts/fetch-whisper-model.sh base` and bundle it (see
[`worker/Resources/README.md`](worker/Resources/README.md)).

## Google Doc output (stubbed)

`create_google_doc` currently writes a local Markdown file (under the app's
Application Support directory) and returns a `GoogleDocRef` pointing at it. The
real Google Docs API integration is intentionally isolated to that one activity so
it can be dropped in later without touching the workflow or anything else.

## Configuration

Everything is configured in the app's **Settings** (⌘,): role, AI provider + key,
AI assistance toggle, and tuning knobs (chunk length, analysis cadence, warmup,
max suggestions). Connection defaults to a local Temporal dev server; set the
Temporal Cloud fields to switch (TLS is enabled automatically with an API key).
The task queue is derived per-machine so users sharing a namespace stay isolated.

| Knob | Default | Meaning |
| --- | --- | --- |
| Chunk length | `20s` | Audio window per transcription/signal |
| Analysis cadence | `3` chunks | Active-listening cadence |
| Warmup | `5` min | Elapsed call time before any live guidance is surfaced |
| Max suggestions | `5` | Max live suggestions shown at once (ranked; lowest/oldest evicted) |

## Project layout

```
ziggy-notes/
├── build_dmg.sh           # build the app (+ in-process worker) and package a DMG
├── scripts/
│   └── fetch-whisper-model.sh   # optionally bundle the WhisperKit model offline
├── worker/                # in-process Swift Temporal worker (compiled into the app)
│   ├── WorkerModels.swift       # Codable models (the wire contract)
│   ├── WorkerConfig.swift       # tuning knobs, populated from Settings
│   ├── Prompts.swift            # sales-expert + summary prompts + role injection
│   ├── LLMClient.swift          # OpenAI + Anthropic structured completion
│   ├── ZiggyActivities.swift    # analyze/identify/summarize/gdoc + capture_audio
│   ├── AudioCapture.swift       # AVAudioEngine mic + ScreenCaptureKit system audio
│   ├── Transcriber.swift        # WhisperKit (CoreML) on-device transcription
│   ├── MeetingWorkflow.swift    # durable orchestrator (polled via get_updates)
│   ├── WorkerRuntime.swift      # TemporalWorker + client, run in-process
│   ├── WorkerLog.swift          # routes worker/SDK logs to the in-app Logs view
│   └── Resources/               # bundled ae/sa/bdr role guidance (+ optional model)
└── ui/                    # macOS SwiftUI app (bundles & runs the worker)
    ├── project.yml              # XcodeGen project (source of truth)
    └── ZiggyNotes/              # app sources
```
