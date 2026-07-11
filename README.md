# Kaze

Open-source alternative to [rewind.ai](https://rewind.ai) — continuation of OpenRewind (forked from [OpenRecall](https://github.com/openrecall/openrecall)), renamed "Kaze" (風, Japanese for "wind").

## Status: Alpha 0.8.0 — Apple Silicon only (multi-platform planned via Electron)

## Features

- GUI app, no terminal/deps required
- Screenshot every 2s → encoded to video
- Full-screen scrollable "rewind" timeline (Rewind-style)
- Rewind window excludable from its own screenshots

## Roadmap

- **Native OCR** — OS-provided OCR APIs (macOS/Windows). Refs: [ocrit](https://github.com/insidegui/ocrit/) ([our fork](https://github.com/alikia2x/ocrit)), [Windows.Media.Ocr.Cli](https://github.com/zh-h/Windows.Media.Ocr.Cli)
- **Big-little scheduling** — Swift QoS-class helper to pin work (e.g. video encoding) to Apple Silicon Efficient cores, cutting peak CPU/power. [Apple docs](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/PrioritizeWorkWithQoS.html)
- **More features** — tracking [OpenRecall's feature list](https://github.com/openrecall/openrecall/discussions/9)
