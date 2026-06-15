# Magic Voice

[![CI](.github/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)

Speak in any app. Magic Voice turns your voice into text on your Mac, then puts it where your cursor already is.

It is local-first, menu-bar quiet, and built for people who want the speed of voice without sending audio to someone else's server.

Hold `fn` to dictate. Double-tap `fn` to start and stop. Keep writing.

## Why Magic Voice

- **Your voice stays local.** Audio is captured and transcribed on your Mac with an MLX/Nemotron sidecar.
- **It works where you work.** Magic Voice inserts the final text into the active field with Accessibility, then falls back to clipboard paste when needed.
- **The shortcut feels native.** The app can borrow the `fn` key while it runs, so Apple Dictation does not double-fire.
- **No noisy app window.** It lives in the menu bar, shows a small recording overlay, and gets out of the way.
- **Built in the open.** The app is MIT licensed and shaped around small seams for new speech engines, injectors, and runtime options.

## What Works Today

| Area | Status |
|---|---|
| Dictation | Hold-to-talk and double-tap toggle |
| Transcription | Local Nemotron MLX streaming model, plus lower-memory 8-bit option |
| Text insertion | Accessibility insertion with clipboard paste fallback |
| Permissions | Microphone and Accessibility only |
| Privacy | No audio upload in the current local engine path |
| Menu bar | Compact control center, recent transcripts, microphone/language/shortcut pickers |
| Runtime | Developer `uv` flow works; public packaged runtime is in progress |

## Public Install Status

A signed public download is not ready yet. The first public install target is a signed and notarized DMG for Apple Silicon Macs, with a drag-to-Applications flow and manual updates from the website or GitHub Releases.

Public builds are intended to be no-terminal: users should not need Homebrew, Xcode, or `uv` installed. On first run, Magic Voice will download its managed Python environment and the selected speech model into Application Support before dictation becomes available. The default model is about 1.2 GB.

## Quick Start

Magic Voice is ready for local development. A signed public DMG is not ready yet, so these steps are for developers working from source.

1. Install [`uv`](https://docs.astral.sh/uv/):

   ```sh
   brew install uv
   ```

2. Open the Xcode project:

   ```sh
   open magic-voice.xcodeproj
   ```

3. Select the `magic-voice` scheme and run with Cmd-R.

4. Grant **Microphone** and **Accessibility** when macOS asks.

5. Hold `fn` to dictate, or double-tap `fn` to start and stop.

On the first dictation after a clean clone, the sidecar downloads the default speech model:

```text
mlx-community/nemotron-3.5-asr-streaming-0.6b
```

The model is about 1.2 GB. Apple Silicon is required for the first public install target and strongly recommended for development.

## Requirements

- macOS 26.2 or later for the current Xcode project target
- Xcode 26 or later
- [`uv`](https://docs.astral.sh/uv/) for the Python sidecar
- Apple Silicon Mac recommended for MLX and MLX Audio

## Privacy

Magic Voice is designed around local speech recognition.

| Permission | Why |
|---|---|
| Microphone | Records your dictation |
| Accessibility | Detects the activation key and inserts text into the focused app |

The clipboard fallback temporarily replaces the system clipboard, sends Command-V, then restores the previous clipboard contents. Final transcripts are stored locally in the recent-history list.

The model and Python packages are downloaded on demand through `uv` and Hugging Face tooling. Before shipping a public binary, verify all dependency and model licenses.

## Roadmap

The near-term goal is simple: make Magic Voice as easy to try as the polished commercial apps while keeping the local-first promise clear.

| Priority | Pending work |
|---|---|
| Release | Signed app, notarized DMG, bundled or managed `uv`, manual download updates |
| First run | Friendly onboarding, model download progress, permission recovery |
| Writing quality | Cleanup mode, filler removal, punctuation polish, custom dictionary |
| Power use | App-aware modes, selected-text edit mode, context-aware correction |
| Docs | Demo media, install screenshots, release checklist, license inventory |

## Develop

Build:

```sh
xcodebuild -project magic-voice.xcodeproj -scheme magic-voice -configuration Debug build
```

Test:

```sh
xcodebuild -project magic-voice.xcodeproj -scheme magic-voice test
```

Regenerate the app icon:

```sh
swift scripts/render_app_icon.swift
```

## Project Layout

```text
magic-voice/
  Audio/            AVFoundation capture and 16 kHz mono float32 WAV side channel
  Hotkeys/          Activation key monitor, gesture machine, dictation session
  STT/              TranscriptionEngine seam and SidecarTranscriptionEngine
  TextInjection/    Accessibility and clipboard text insertion adapters
  MenuBar/          Menu bar control center and Settings tabs
  NotchOverlay/     Floating recording indicator
  Permissions/      Microphone and Accessibility status
magic-voiceTests/   Swift Testing unit tests and fakes
sidecar/            Python Nemotron MLX transcription process
docs/               Packaging notes and design plans
```

## Release Status

The source repo is usable for local development. Public binary distribution still needs a packaging pass: deployment target check, bundled sidecar resources, runtime strategy, notarization, smoke test, and third-party license inventory.

See [docs/PACKAGING.md](docs/PACKAGING.md) before shipping.

## License

MIT - see [LICENSE](LICENSE).
