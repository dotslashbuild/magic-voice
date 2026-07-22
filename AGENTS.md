# Agent Instructions

## Repository Overview

Magic Voice is a local-first macOS menu-bar dictation app. The app is written in
Swift/SwiftUI and launches a Python MLX sidecar for speech-to-text. Work from the
repository root unless a command below says otherwise.

Read these files before making broad changes:

- `README.md` for setup, supported behavior, and the project layout.
- `CONTEXT.md` for canonical domain terms and architectural contracts.
- `CONTRIBUTING.md` for contributor expectations and sensitive areas.
- `docs/PACKAGING.md` for distribution, signing, runtime, and resource constraints.

## Project Layout

- `magic-voice/`: macOS application source.
- `magic-voice/Hotkeys/`: activation monitoring, gesture state, and session orchestration.
- `magic-voice/STT/`: backend-neutral transcription contract and Python sidecar adapter.
- `magic-voice/TextInjection/`: Accessibility insertion and clipboard fallback.
- `magic-voice/MenuBar/` and `magic-voice/NotchOverlay/`: user-facing SwiftUI surfaces.
- `magic-voiceTests/`: Swift Testing unit tests and test doubles.
- `sidecar/`: Python 3.11+ MLX transcription process and locked dependencies.
- `scripts/smoke_sidecar.py`: end-to-end JSONLines sidecar protocol smoke test.

## Build And Test

The project currently requires macOS 26.2+, Xcode 26+, and `uv`. Match CI by
disabling code signing for command-line builds and tests:

```sh
xcodebuild \
  -project magic-voice.xcodeproj \
  -scheme magic-voice \
  -configuration Debug \
  build \
  CODE_SIGNING_ALLOWED=NO

xcodebuild \
  -project magic-voice.xcodeproj \
  -scheme magic-voice \
  -configuration Debug \
  test \
  CODE_SIGNING_ALLOWED=NO
```

For Python-only changes, run the narrow checks first:

```sh
uv sync --project sidecar --frozen
uv run --project sidecar python -m py_compile sidecar/sidecar.py
python3 -m py_compile scripts/smoke_sidecar.py
```

The full sidecar smoke test boots the model and may download about 1.2 GB on its
first run. Run it when changing the JSONLines protocol, streaming behavior, model
integration, or runtime launch path, and state clearly when it was not run:

```sh
python3 scripts/smoke_sidecar.py
python3 scripts/smoke_sidecar.py path/to/16k-mono-f32.wav
```

## Architecture Contracts

- Keep `TranscriptionEngine` backend-neutral and stream-in/stream-out. Backend
  limitations belong inside adapters; `DictationSession` must not branch on them.
- Audio passed to transcription is 16 kHz mono float32. Preserve that contract
  across capture, buffering, encoding, and sidecar changes.
- A transcription session emits `.ready`, zero or more `.partial` events, and
  exactly one terminal `.final` or `.failed`. Cancellation emits no later events.
- The notch overlay may show partial text, but the focused app receives one final
  insertion. Do not stream partial text into the target app.
- `FallbackInjector` owns insertion policy: Accessibility first, clipboard paste
  second. Clipboard fallback must restore every original pasteboard item.
- Keep status and health derivation in `MenuBarStatusModel`; SwiftUI views render
  the model and should not duplicate health logic.
- Activation timing stays inside `HotkeyGestureMachine`. Do not expose timing or
  threshold tuning as settings without an explicit product decision.
- Keep persisted `UserDefaults` key strings stable. Treat changes as migrations
  and add round-trip coverage.
- The sidecar uses stdout exclusively for JSONLines protocol messages through
  `emit()`. Send diagnostics to stderr through `log()`.
- Keep `sidecar/uv.lock` in sync with `sidecar/pyproject.toml`. The app launches
  developer and managed runtimes with `uv run --frozen`.

## Swift Conventions

- Match the existing Swift 5 style and use Swift Testing (`import Testing`,
  `@Test`, and `#expect`) for unit tests.
- Keep UI-observable controllers and protocols on `@MainActor`; make actor
  crossings explicit instead of weakening isolation.
- Prefer small protocols and injected collaborators around macOS APIs so global
  state, permissions, process launch, and pasteboard behavior remain testable.
- Preserve the existing no-third-party-Swift-dependency approach unless the task
  explicitly requires and justifies a dependency.
- Add focused tests beside the closest existing test suite. Tests must use
  ephemeral `UserDefaults` suites and fakes; never modify real user preferences,
  permissions, the clipboard, or the fn-key preference from a unit test.
- New Swift files under synchronized source/test groups are discovered by Xcode.
  Resource changes still require checking Copy Bundle Resources in
  `magic-voice.xcodeproj/project.pbxproj`.

## Privacy And System Safety

Treat these paths as high risk and review their cleanup and failure behavior:

- `DictationConflictController` changes the user-wide
  `com.apple.HIToolbox AppleFnUsageType` preference. Preserve normal-release and
  next-launch crash recovery of the original value.
- `ClipboardPasteInjector` temporarily replaces the clipboard. Preserve all
  pasteboard items and restore them after both success and failure.
- `SidecarTranscriptionEngine` and `sidecar/sidecar.py` own subprocess lifetime,
  model downloads, and message ordering. Avoid orphan processes and stale events.
- `SettingsStore` persists recent transcripts locally. Do not add uploads,
  telemetry, or new retention without an explicit product and documentation change.

App Sandbox must remain disabled: global key monitoring, Accessibility insertion,
clipboard fallback, and sidecar process launch are incompatible with the current
design. Do not change permissions, entitlements, usage descriptions, model IDs,
or network behavior without updating the relevant README and packaging notes.

## Validation Expectations

- Run the narrowest relevant tests while iterating, then run the full Swift test
  command for changes that affect shared contracts or application wiring.
- Run a no-signing build for changes to Swift source, resources, Xcode settings,
  or bundle behavior.
- For hotkey, permission, Accessibility, clipboard, menu-bar, and notch behavior,
  note any required manual macOS verification. Unit tests cannot prove global
  event monitoring or real cross-application insertion.
- For packaging changes, verify that `sidecar.py`, `pyproject.toml`, and `uv.lock`
  are bundled together and follow `docs/PACKAGING.md` before claiming readiness.
- Do not claim a distributable release is ready unless signing, notarization,
  clean-account runtime setup, model/dependency licensing, and the packaging smoke
  checklist have all been completed.

## Change Discipline

- Keep changes focused and avoid unrelated refactors or project-file churn.
- Preserve the local-first privacy promise and the domain vocabulary in
  `CONTEXT.md`.
- Update tests and user/developer documentation when behavior, commands,
  permissions, model selection, runtime setup, or packaging assumptions change.
- Never commit generated build products, model files, virtual environments,
  user-specific Xcode state, secrets, or `.context/` workspace notes.
