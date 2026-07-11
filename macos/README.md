# Kaze — Native macOS App

Native Swift/SwiftUI port of the Electron app in the repo root. Menu-bar app, Apple Silicon, macOS 15+. No Xcode required — builds with Command Line Tools via Swift Package Manager.

## Build & run

```sh
cd macos
./build-app.sh          # swift build + assembles dist/Kaze.app (ad-hoc signed)
open dist/Kaze.app
```

`./build-app.sh --debug` for a debug build. `swift build` alone compiles without bundling (running unbundled disables mic/screen capture — TCC needs the app bundle's Info.plist).

### Permissions (required once)

System Settings → Privacy & Security:
- **Screen & System Audio Recording** → enable Kaze (screenshots + system audio). If the first prompt was declined, macOS will not re-prompt — toggle manually, then relaunch Kaze.
- **Microphone** → enable Kaze (prompted on first launch).

The Settings window (menu bar → Settings…) shows live permission status.

## What it does (parity with the Electron app)

- Screenshot of the primary display every 2s → `frame` row; Kaze's own windows are excluded from capture.
- Batches of 90 frames (3 min) encoded to video; screenshot N = video frame N at 30fps, seek = `videoFrameIndex / 30`. Leftover frames are flushed on stop/quit.
- Mic + system audio mixed to mono 16kHz WAV in 30s chunks → whisper.cpp (base-q5_0 + CoreML encoder) → `transcription` rows, language auto-detect. **Audio recording is OFF by default** (opt-in via menu bar or Settings); both recording toggles persist across launches.
- FTS5 `text_search` over OCR + transcriptions (trigger-synced).
- 14-day retention, run at startup and quit.
- CPU-aware scheduler: encoding deferred while CPU ≥ 75%.
- Rewind window: scrub with wheel/trackpad, arrows (Shift = ×10), Cmd+F or `/` to search, `t` for transcript panel. Library window: storage, files, transcriptions, live status. Same data directory and SQLite schema (v4) as the Electron app — existing data carries over.

## What's different (improvements)

| Area | Electron | Native |
|---|---|---|
| Encoding | ffmpeg subprocess (concat demuxer, h264) | AVAssetWriter, hardware HEVC — no ffmpeg binary |
| Frame extraction | ffmpeg `-ss` (keyframe-approximate) | AVAssetImageGenerator, exact-frame, zero tolerance |
| OCR | schema only, never implemented | Apple Vision, every frame OCR'd before its PNG is deleted |
| Stuck tasks | encoding tasks stuck at status=1 after crash | reset to pending on launch, failed encodes retried |
| Search jump | could only snap to already-loaded frames | reloads timeline around any timestamp |
| Audio timestamps | chunk stamped at write time (end, ~30s late) | stamped with true chunk start |
| HTTP API | Hono server on localhost + API key | none — UI reads SQLite directly |

Dropped for now: i18n (only English was complete upstream), the `libsimple` Chinese FTS tokenizer (was loaded but never wired up), win32/linux targets.

## Architecture

```
Sources/Kaze/
├── KazeApp.swift            @main, MenuBarExtra + windows, app delegate
├── AppState.swift           service container, recording toggles, shutdown
├── Core/                    Constants, Paths, Log, Scheduler (CPU-aware), CPUMonitor, AtomicFlag
├── Database/                SQLiteDB (thin C-API wrapper), Schema (v4), Store (all queries), Models
├── Capture/                 ScreenshotService (ScreenCaptureKit), AudioCaptureService (ported from native/audio-capture)
├── Processing/              EncodingService (AVAssetWriter), OCRService (Vision), TranscriptionService (whisper.cpp),
│                            RetentionService, FrameExtractor (AVAssetImageGenerator)
└── UI/                      RewindView/Model/Components, LibraryView, SettingsView
```

whisper.cpp binary + model are copied from `../bin/darwin-arm64/` into `Kaze.app/Contents/Resources/bin/` at build time. For unbundled dev runs, set `KAZE_BIN_DIR=/path/to/bin/darwin-arm64` (falls back to the repo path automatically).

Do not run the Electron app and the native app at the same time — they share the data directory and would double-capture.

## Phase 2: daily AI workflow analysis (built)

The OCR text + transcriptions are the raw material ("~8,640 lines of free metadata per day"). The analyzer lives in `Sources/Kaze/Analysis/`:

- **DayCompactor** — pulls a day's OCR frames + transcripts and collapses runs of near-identical screens (Jaccard ≥ 0.85) into an activity timeline. Kaze captures every 2s (~14k frames/day), so this de-duplication is what makes the day cheap to analyze — a typical day compacts to a few hundred segments / ~10–15k tokens. Caps at 400 longest-dwell segments (logged when it truncates).
- **LLM providers** (`LLMProvider.swift`, `Providers.swift`) — pluggable provider abstraction. Anthropic (`/v1/messages`, `output_config.format`), OpenAI (`/v1/chat/completions`, `response_format` json_schema strict), and Google Gemini (`generateContent`, `responseSchema`). All use structured output so observations come back as validated JSON; `SchemaTranslator` converts the shared schema to Gemini's OpenAPI-subset dialect. Keys are stored per-provider in Keychain; pick the active provider + model in Settings. Defaults: `claude-opus-4-8`, `gpt-4o`, `gemini-2.0-flash` (all editable — set a newer id when you have access).
- **AnalysisService** — compacts the day → asks the active provider for a summary + repeated low-value behaviors → merges into the **observations ledger** (`analysis.db`, separate from `main.db`). A behavior seen on **3 distinct days** is confirmed and its suggestion surfaces in the morning digest + a macOS notification.
- **Scheduling** — a 15-min menu-bar timer generates the previous day's digest once past 07:00 (idempotent). Also: menu → **Run Daily Analysis Now**, and the **Insights** window (digests, suggestions, ledger, and a dry-run prompt preview).

**Setup:** menu bar → Settings → AI Analysis → choose a provider and paste its API key (stored in Keychain; or set `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY`). Nothing else is required — analysis no-ops until a key is present.

**Vision sampling (built):** OCR is done locally by Apple Vision (free, on-device). During analysis, segments where real time was spent but OCR read little (≥2 min dwell, ≤18 salient tokens) get their representative frame exported as a downscaled JPEG (≤1280px) and sent — up to 12 per day — to the active provider's vision API for a one-line description, which is attached to the timeline as `[visual: …]`. All three providers support this.

**Ask-the-user loop:** screens that even vision can't identify become **questions** in the Insights window (thumbnail + "What were you doing here?"). Answers persist in `analysis.db` and are injected into every future analysis prompt ("trust these explanations"), so Kaze's understanding of your ambiguous work accrues over a few days. Questions are deduped per (day, time), capped at 5/day, and dismissible. If a vision call fails outright, the top ambiguous segments become questions directly.

**Obsidian journal (`JournalExporter.swift`):** an improvement journal written straight into your vault (a vault is just Markdown, so no plugin/API). Settings → Journal: pick a detected vault (or any folder), and every analysis writes:
- `Kaze <day>.md` — the digest as a daily note (frontmatter-tagged `kaze/digest`), with a seeded "My notes" section; everything below the `<!-- kaze:end -->` marker is yours and survives re-export.
- `Kaze Improvements.md` — an **append-only checklist** of confirmed suggestions (one anchor-deduped line each). Tick a box when you adopt one; Kaze never edits existing lines.

One-way export: `analysis.db` stays the source of truth. "Export existing history" in Settings backfills. Headless: `KAZE_JOURNAL_EXPORT=1` (+ optional `KAZE_JOURNAL_PATH`). If your vault syncs (Obsidian Sync/iCloud), the journal already crosses machines — a soft start on phase 3.

**Headless hooks** (testing/cron, exercise the real pipeline without UI):
- `KAZE_ANALYZE_DRYRUN=1 Kaze` — compact yesterday, print segment count + token estimate + prompt preview, exit.
- `KAZE_ANALYZE_RUN=1 Kaze` — full analysis of yesterday (needs a key for the active provider), print summary + ledger, exit.
- `KAZE_LEDGER_SELFTEST=1 Kaze` — verify the 3-day confirmation logic against a throwaway DB.
- `KAZE_PROVIDER_SELFTEST=1 Kaze` — verify provider plumbing (Gemini schema translation, per-provider Keychain round-trip).

### Phase 3 (later): cloud sync

Push the ledger + digests (not raw recordings) to a backend so history survives across machines and analysis can run while the Mac is off. The `analysis.db` tables (`observation`, `digest`) are the sync surface — deliberately small and already separate from the recording data.
