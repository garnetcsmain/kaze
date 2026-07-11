# CLAUDE.md

Guidance for Claude Code in this repo.

## Project Overview

Kaze (formerly OpenRewind): open-source rewind.ai alternative. Desktop app — periodic screenshots → video encoding, audio capture + transcription, OCR, full-screen "rewind" timeline UI. Apple Silicon only (current). Electron + React + TypeScript.

Internal naming note: the app/brand is "Kaze"; the "rewind" timeline feature (`pages/rewind/`, `/rewind` route, window titled "Kaze") kept its original name — it describes the scrubback UI, not the product.

## Native macOS app (macos/) — the active codebase

The Electron app has been ported to a native Swift/SwiftUI menu-bar app in `macos/` (SPM, no Xcode needed; `macos/build-app.sh` → `macos/dist/Kaze.app`). See `macos/README.md` for architecture, parity notes, and the phase-2 AI-analysis roadmap. Key facts:

- Same data dir + SQLite schema v4 as the Electron app (`~/Library/Application Support/Kaze/Record Data/`) — never run both apps at once.
- ffmpeg replaced by AVAssetWriter (HEVC) / AVAssetImageGenerator; OCR implemented for real via Apple Vision (the Electron app had schema only); whisper.cpp binary + model reused from `bin/darwin-arm64/`.
- New feature work should target `macos/`; the Electron code below is reference/legacy.

## Build & Development Commands

- **Dev:** `bun run dev` — React (Vite) + Electron concurrently
- **Build React:** `bun run build:react` — Vite build, renderer
- **Build Electron:** `bunx gulp build` — compiles TS, copies assets/binaries/locales → `dist/electron/`
- **Package:** `bun run build:electron` — electron-builder → `dist/release`
- **Format:** `bunx prettier --write .`
- **Lint:** `bunx eslint .`
- **PATH:** bun at `/Users/fsulbaran/.bun/bin` — `export PATH="/Users/fsulbaran/.bun/bin:$PATH"` if `bunx` missing
- No test scripts configured

## Architecture

### Dual-process Electron

**Main** (`src/electron/`): Gulp + gulp-typescript → `dist/electron/`. `tsconfig.json` (ESNext/ESNext).
**Renderer** (`src/renderer/`, `pages/`, `components/`): Vite + React → `dist/renderer/`. `tsconfig.app.json` (ES2020/JSX). Path aliases via `vite-tsconfig-paths`, `baseUrl: "."` — e.g. `pages/rewind`, `components/settings` resolve from root.

### Main process

- `index.ts` — entry: tray, 3 windows (main/settings/library), DB init, scheduler, Hono server. Tray menu toggles screen/audio recording.
- `createWindow.ts` — window factories. Windows hide (not destroy) on close, reopen from tray. `isQuitting` flag gates real close on app quit. **Close callbacks must be `() => {}`, never `() => (window = null)`** — nulling breaks tray reopen.
- `backend/scheduler.ts` — task scheduler: pause/resume/delay, CPU-aware (defers LOW_POWER tasks at >75% load).
- `backend/screenshot.ts` — capture every 2s. `db.open` guards vs. shutdown crashes.
- `backend/encoding.ts` — batches screenshots → video via FFmpeg. Needs 90+ frames (3min @ 0.5fps) to queue, unless `flushPendingFrames()` forces it (stop/quit). Video = compressed storage; each frame is a DB row with `videoFrameIndex` for seeking.
- `backend/audio-capture.ts` — spawns Swift binary (`native/audio-capture/`), mic+system audio via ScreenCaptureKit. 30s `.wav` chunks, `YYYY-MM-DD_HH-mm-ss.wav`. `intentionallyStopped` flag blocks auto-restart on quit.
- `backend/transcription.ts` — whisper.cpp on audio chunks → `transcription` table, w/ language detection. Audio files NOT auto-deleted post-transcription (manual, via library).
- `backend/retention.ts` — deletes video/audio/orphaned DB rows >14d old. Runs on startup+quit only (no timer).
- `backend/recognition.ts` — OCR.
- `backend/init.ts` — SQLite init+migration. Loads `libsimple` FTS ext (Chinese search).
- `backend/migrate/` — versioned schema migrations (current: v3).
- `backend/consts.ts` — shared constants: frame rate, audio chunk duration, intervals, retention days.
- `server/index.ts` — Hono API (dynamic port from 12412):
  - `/timeline`, `/frame/:id` — rewind UI frame access
  - `/search` — FTS5 across OCR+transcriptions
  - `/transcriptions` — time-range query
  - `/library/stats` — file listings/sizes
  - `/library/status` — live activity (encoding/transcribing/queue counts)
  - `/library/transcriptions` — recent transcriptions
  - `/library/file` (DELETE), `/library/transcription/:id` (DELETE)
- `preload/` — `.cjs` preloads (rewind, settings, library, OS name). Library exposes `libraryWindow.close()`, `.openFolder()`, `appGlobal.requestApiInfo()`.
- `utils/` — by concern: `backend/`, `fs/`, `logging/`, `network/`, `platform/`, `video/`.

### Renderer

- `src/renderer/app.tsx` — root, HashRouter. Routes: `/settings`, `/rewind`, `/library`.
- `src/renderer/state/` — Jotai atoms (e.g. `apiInfoAtom`).
- `pages/rewind/` — full-screen scrubable timeline.
- `pages/library/` — library window (Liquid Glass design): storage overview, video/audio file lists, transcriptions (copy/delete), DB info, live encoding/transcription status bar. Refreshes on focus.
- `pages/library/index.css` — glass material: backdrop-filter blur, translucent bg, dark mode via `@media (prefers-color-scheme: dark)` (not class-based).
- `pages/settings/` — settings page.
- `components/settings/` — settings UI.

### Scheduler tasks

| Task ID | Function | Interval | Priority | Notes |
|---|---|---|---|---|
| `screenshot` | `takeScreenshot` | 2s | ANY | Paused when recording stopped |
| `check-encoding` | `checkFramesForEncoding` | 5s | ANY | Queues at 90+ frames |
| `process-encoding` | `processEncodingTasks` | 10s | LOW_POWER | FFmpeg, CONCURRENCY=1 |
| `delete-screenshots` | `deleteUnnecessaryScreenshots` | 20s | ANY | Removes encoded screenshots |
| `process-transcription` | `processTranscriptionTasks` | 10s | ANY | whisper.cpp, CONCURRENCY=1 |

### Tray menu

Search (main/rewind) · Settings · Library · Stop/Start Screen Recording (pause/resume screenshot+encoding, flush on stop) · Stop/Start Audio Recording (Swift process; transcription scheduler keeps draining chunks) · Quit

### Key technical details

- **DB:** SQLite via `better-sqlite3`, WAL mode. Version tracked in `config` table. FTS5 `text_search` synced from `recognition_data`/`transcription` via triggers. See `docs/database-structure.md`, `docs/database-changelog.md`.
- **IPC:** renderer gets port+API key via `ipcMain.handle('request-api-info')`, then talks HTTP to Hono server.
- **Shared state:** `memory-cache` holds DB connection, port, API key across main-process modules.
- **i18n:** `i18next`, `i18n/` dir (en, es, fr, de, it, ja, ko, zh-CN, ar). Main: `i18next-fs-backend`. Renderer: `i18next-browser-languagedetector`.
- **Binaries:** platform binaries in `bin/{platform}-{arch}/` (`libsimple`, `whisper-cpp`) → copied to `dist/electron/bin` at build.
- **Native audio:** Swift, `native/audio-capture/`, ScreenCaptureKit + AVAudioEngine. Mic/system buffers mixed in `checkAndWriteChunks()`.
- **Dark mode:** Tailwind `media` strategy. Custom CSS: `@media (prefers-color-scheme: dark)`, never `.dark` class.
- **Windows:** persist app lifetime, hide on close/show on tray click. Never null window refs in close callbacks.

### Known issues

- **Encoding concurrency:** cache-based (`backend:encodingTasksPerforming`). FFmpeg hang/crash w/o callback → cache entry blocks all future encoding. No timeout/recovery.
- **Encoding transaction bug:** FFmpeg error → ROLLBACK reverts status, but task stays status=1 in practice → never retried.
- **No encoding progress:** single `exec()` call, no tracking. Real % needs FFmpeg stderr parsing or streaming.

### ESLint

Flat config (`eslint.config.js`): `typescript-eslint`, `react-hooks`, `react-refresh`. Unused vars require `_` prefix.
