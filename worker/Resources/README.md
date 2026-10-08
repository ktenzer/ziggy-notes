# Bundled worker resources

These files are copied into the app bundle's `Resources/` at build time
(see `ui/project.yml`).

- `ae.md`, `sa.md`, `bdr.md` — role guidance injected into the LLM prompts,
  loaded by `RoleGuidance.load(_:)`.

## Offline WhisperKit model (optional, fully offline)

By default the app downloads the WhisperKit `base` model from Hugging Face on
first launch (seamless, but needs network once). To ship it **fully offline**,
place the CoreML model folder here so it gets bundled:

```
worker/Resources/whisper-models/openai_whisper-base/
```

A convenience script fetches it for you:

```
./ziggy-notes/scripts/fetch-whisper-model.sh base
```

Then add the folder to the Xcode project as a **folder reference** (so its
internal structure is preserved) under the app target's Copy Resources phase,
or add it to `ui/project.yml` as:

```yaml
      - path: ../worker/Resources/whisper-models
        type: folder
        buildPhase: resources
```

`Transcriber` prefers this bundled folder and only falls back to downloading
when it is absent.
