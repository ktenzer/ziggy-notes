# Ziggy Notes

**An active-listening meeting note-taker for Temporal sales calls, built on Temporal.**

Ziggy is a Temporal-native take on [Abridge](https://www.abridge.com/) — the
tool that listens to a doctor/patient visit and, in real time, surfaces
suggestions and then writes up a structured summary. Ziggy does the same for
**Temporal sales conversations**: it records the call, transcribes it live,
and acts as an expert Temporal sales engineer whispering in your ear — "bring
this up", "explain Continue-As-New here", "that's an objection, answer it like
this" — then produces a concise summary + next steps as a Google Doc when the
meeting ends.

It is used by Temporal and built on Temporal.

> Status: backend only. The UI will be a separate SwiftUI app; everything Ziggy
> produces is streamed out over [Temporal Workflow Streams](https://docs.temporal.io/workflow-streams)
> so the UI can subscribe later with zero backend changes. For now, `subscribe.py`
> is a terminal stand-in for that UI.

## How it works

```
starter.py ─ start ─▶ MeetingWorkflow ──────────── Workflow Stream ──▶ subscribe.py / Swift UI
stop.py ─ signal ─▶   │  (hosts stream,              (transcript, suggestions,
                      │   keeps transcript)           summary, lifecycle)
                      │
                      ├─▶ capture_audio (long-running Activity)
                      │     mic = Temporal  +  system output (BlackHole) = Customer
                      │     faster-whisper per chunk ─ signals each chunk back ▲
                      │
                      ├─▶ identify_speakers (every N chunks, LLM) ─▶ speakers
                      ├─▶ analyze_conversation (every N chunks, LLM) ─▶ suggestions
                      └─▶ summarize_meeting + create_google_doc (on stop/silence)
```

- **One durable `MeetingWorkflow` per meeting** orchestrates everything and hosts
  the stream. It never reads its own stream (unsupported by design); it keeps its
  own transcript buffer for analysis and the final summary.
- **`capture_audio`** is a single long-running, heartbeating Activity so there
  are no gaps in the recording. It captures the microphone (you, the rep) and the
  system audio output (the customer, via a loopback device), transcribes each
  `CHUNK_SECONDS` window locally with faster-whisper, and pushes each transcribed
  segment back to the workflow as a small `add_transcript_chunk` Signal. If the
  worker restarts or crashes mid-meeting, capture is **rescheduled and resumes**
  (it distinguishes a worker shutdown from a `stop_recording`), so the meeting
  only ends on a stop Signal or the silence timeout — never because a worker
  bounced. Audio during the restart gap is lost.
- **`identify_speakers`** runs every `ANALYZE_EVERY_N_CHUNKS` chunks (and once
  more before the summary) to attribute each line to a speaker. See
  [Speaker identification](#speaker-identification).
- **`analyze_conversation`** runs every `ANALYZE_EVERY_N_CHUNKS` chunks (once the
  conversation has warmed up for `ANALYSIS_WARMUP_MINUTES` of elapsed call time)
  and maintains a live, ranked board of at most `MAX_ACTIVE_SUGGESTIONS`: each
  pass returns the full desired set so applied/irrelevant advice is dropped, new
  advice is added, and items are re-prioritized. Published to the `suggestions`
  topic and returned in full by the `get_updates` query.
- On a `stop_recording` signal or `SILENCE_TIMEOUT_SECONDS` of silence, the
  workflow runs **`summarize_meeting`** and **`create_google_doc`**, publishes the
  summary, and returns the full transcript + summary + doc link.

### Respecting Temporal limits

- **2 MB per-payload limit** — per-chunk signals are tiny. The growing transcript
  is appended to the stream as small deltas, never one giant payload. The full
  transcript (summary input and final result) can be large, so an **External
  Storage** claim-check driver (`ziggy/storage.py`) offloads oversized payloads to
  disk and stores only a reference in history. Both are configured in
  `ziggy/config.py` and shared by the worker and all clients.
- **50k events / 50 MB per execution** — each chunk is ~1 event; a normal sales
  call is comfortably within budget. For multi-hour edge cases, Continue-As-New is
  the documented next step (Workflow Streams carries its state across the boundary).

> Workflow Streams and External Storage are Temporal **Public Preview** features.

## Speaker identification

Who-said-what is resolved with a two-layer approach and a graceful fallback
cascade:

1. **Audio source (ground truth).** Every transcript chunk is tagged with its
   source: the **mic** is always the Temporal rep's side, and the **system audio
   output** (BlackHole) is the remote/customer side.
2. **Name attribution (best-effort).** The `identify_speakers` Activity feeds the
   cumulative transcript (each line tagged with its index + source + timestamp) to
   the LLM, which extracts names from self-introductions ("my name is John", "this
   is Sarah from Acme") and attributes each line to a person.

The resolved label for each line follows this cascade:

```
name known        → "John (Temporal)" / "Sarah (Customer)"  (or just "John" if org unclear)
name unknown       → source fallback:  mic → "Temporal",  output → "Customer"
```

So if people introduce themselves you get real names; if they don't, you still
know the side ("Temporal" vs "Customer"), and when in doubt an output-channel
voice is "Customer". The mic is always "Temporal" (optionally your rep's name via
`starter.py --rep-name "Keith"`).

Attribution is republished on the **`speakers`** stream topic as a
`SpeakerMapEvent` (`index → label` + roster), so a subscriber/UI can retroactively
upgrade earlier lines (e.g. "Customer" → "Sarah (Customer)") as names are learned.
`subscribe.py` demonstrates this.

**Limitation:** this separates *sides* reliably and names people who introduce
themselves, but it does not tell apart multiple distinct voices sharing one
channel (e.g. three customer attendees on the same call audio all start as
"Customer"). True per-voice separation would require audio diarization, which can
be added later as another Activity without changing this contract.

## Prerequisites

- macOS (audio capture is macOS-only here).
- [`uv`](https://docs.astral.sh/uv/) and the Temporal CLI (`brew install temporal`).
- A loopback audio device to capture the customer's voice (see below).
- An LLM key: `OPENAI_API_KEY` (default) or `ANTHROPIC_API_KEY` (set `LLM_PROVIDER=anthropic`).
- Transcription is **local/offline** via faster-whisper (no key needed); the model
  downloads on first run.

### One-time macOS audio setup (capture the customer)

macOS can't capture system output directly, so route it through a virtual
loopback device:

1. Install BlackHole: `brew install blackhole-2ch` (or download from
   [existential-audio/BlackHole](https://github.com/ExistentialAudio/BlackHole)).
2. Open **Audio MIDI Setup** → create a **Multi-Output Device** containing both
   your real speakers/headphones **and** "BlackHole 2ch". Set it as the system
   output during calls so you still hear the call *and* BlackHole receives a copy.
   (In Zoom/Meet you can instead set the meeting's speaker to the Multi-Output
   device.)
3. Confirm device names: `uv run python -m sounddevice`. Put the BlackHole name
   in `SYSTEM_AUDIO_DEVICE` (default `BlackHole 2ch`). Leave `MIC_DEVICE` blank to
   use your default microphone.

If BlackHole isn't configured, Ziggy still runs — it just records the
microphone (rep) only and logs a warning.

## Setup

```bash
cd temporal/ziggy-notes
uv sync
cp .env.example .env      # then edit: set OPENAI_API_KEY (or ANTHROPIC_*), devices
```

`.env` defaults target `temporal server start-dev`. To use **Temporal Cloud**,
set `TEMPORAL_ADDRESS`, `TEMPORAL_NAMESPACE`, and `TEMPORAL_API_KEY` — no code
changes (TLS is enabled automatically when an API key is present).

## Run

Four terminals (all from `temporal/ziggy-notes`):

```bash
# 1. Temporal dev server (skip if using Cloud)
temporal server start-dev

# 2. Worker (must run on the Mac with the mic + BlackHole)
uv run python worker.py

# 3. Start a meeting (recording begins immediately)
uv run python starter.py --title "Acme discovery call" \
    --context-file ziggy/context/temporal_sales_context.md

# 4. Watch the live stream (stand-in for the Swift UI)
uv run python subscribe.py <workflow-id-printed-by-starter>
```

Stop the meeting (until the UI exists):

```bash
uv run python stop.py <workflow-id>
```

On stop (or after `SILENCE_TIMEOUT_SECONDS` of silence) Ziggy summarizes the call
and writes the Google Doc. The summary + doc link stream to `subscribe.py`; the
doc itself is written to `out/<meeting-id>.md` (see Google Doc note below).

## Configuration

All settings live in `.env` (see `.env.example` for the full list). Highlights:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TEMPORAL_ADDRESS` / `TEMPORAL_NAMESPACE` / `TEMPORAL_API_KEY` | localhost | Switch localhost ↔ Cloud |
| `CHUNK_SECONDS` | `20` | Audio window per transcription/signal |
| `ANALYZE_EVERY_N_CHUNKS` | `3` | Active-listening cadence |
| `ANALYSIS_WARMUP_MINUTES` | `5` | Elapsed call time before any live guidance is surfaced |
| `MAX_ACTIVE_SUGGESTIONS` | `5` | Max live suggestions shown at once (ranked; lowest/oldest evicted) |
| `SILENCE_TIMEOUT_SECONDS` | `300` | Auto-stop after this much silence (0 = never) |
| `WHISPER_MODEL` | `base` | faster-whisper model size |
| `LLM_PROVIDER` / `LLM_MODEL` | `openai` | `openai` or `anthropic` |
| `SYSTEM_AUDIO_DEVICE` | `BlackHole 2ch` | Loopback device for customer audio |
| `ZIGGY_EXTERNAL_STORAGE` | `true` | Offload large payloads to stay under 2 MB |
| `STREAM_DRAIN_SECONDS` | `15` | Linger after final publish for slow subscribers |

## Call context (placeholder)

`MeetingInput.call_context` gives the active-listening LLM situational awareness
about *this* account/opportunity. It's a placeholder today — pass a file via
`starter.py --context-file`. Later it will be produced by a separate
workflow/process. Template: `ziggy/context/temporal_sales_context.md`.

## Google Doc output (stubbed)

`activities/gdoc.py` currently writes a local Markdown file under `out/` and
returns a `GoogleDocRef` pointing at it. The real Google Docs API integration is
intentionally isolated to that one file so it can be dropped in later without
touching the workflow or anything else.

## Project layout

```
ziggy-notes/
├── ziggy/
│   ├── config.py      # ENV config + connect_temporal_client (pydantic + external storage)
│   ├── models.py      # Pydantic models (inputs, results, stream events)
│   ├── prompts.py     # Temporal-sales-expert + summary prompts
│   ├── llm.py         # provider-agnostic structured LLM completion
│   ├── storage.py     # local-disk External Storage (claim-check) driver
│   └── context/       # placeholder call-context template
├── activities/
│   ├── capture.py     # long-running mic + system-output capture + faster-whisper
│   ├── analysis.py    # active-listening suggestions
│   ├── summary.py     # final concise summary + next steps
│   └── gdoc.py        # Google Doc (stub)
├── workflows/
│   └── meeting.py     # MeetingWorkflow: stream host + orchestrator
├── worker.py          # registers workflow + activities
├── starter.py         # start a meeting
├── stop.py            # stop a meeting (UI stand-in)
└── subscribe.py       # watch the live stream (UI stand-in)
```
