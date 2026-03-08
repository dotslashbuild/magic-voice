# Contributing to Magic Voice

## Dev Setup

1. Clone the repo, then open the project from the repository root:
   ```sh
   open magic-voice.xcodeproj
   ```

2. Install `uv` (the Python sidecar uses it to manage dependencies):
   ```sh
   brew install uv
   # or: curl -LsSf https://astral.sh/uv/install.sh | sh
   ```

3. Select the `magic-voice` scheme in Xcode and run. The current project target is macOS 26.2. The sidecar resolves its Python dependencies via `uv run --frozen` on first launch.

## Build and Test

```sh
xcodebuild -project magic-voice.xcodeproj -scheme magic-voice -configuration Debug build
xcodebuild -project magic-voice.xcodeproj -scheme magic-voice test
```

## Running the Sidecar Smoke Test

The smoke test boots the sidecar directly and exercises the full JSONLines protocol without building the Swift app:

```sh
python3 scripts/smoke_sidecar.py
# or with a real audio fixture:
python3 scripts/smoke_sidecar.py path/to/16k-mono-f32.wav
```

The first run downloads the STT model (~1.2 GB) and may take a few minutes. Subsequent runs use the cached model. The script exits non-zero on any protocol failure.

When changing sidecar dependency resolution, also test the app launch path. The app uses the checked-in lockfile and `uv run --frozen`; the smoke script currently uses direct `uv run`, so it is not enough to prove the packaged path works.

## Adding an STT Engine

Add a new adapter behind `TranscriptionEngine`. The recording pipeline expects stream-in/stream-out behavior, so non-streaming backends should buffer or coalesce inside the adapter rather than adding capability branches to `DictationSession`.

## App Sandbox

App Sandbox must remain **off**. The app requires Accessibility-based global key monitoring, Accessibility text insertion, clipboard paste fallback, and the ability to launch a Python subprocess — these are not App Store sandbox-friendly. See [docs/PACKAGING.md](docs/PACKAGING.md) for details.

## Privacy-Sensitive Areas

Changes to these areas need extra review:

- `DictationConflictController`: writes the user-wide `com.apple.HIToolbox AppleFnUsageType` preference while the fn activation key is claimed.
- `ClipboardPasteInjector`: temporarily replaces the system clipboard to perform paste fallback, then restores the previous contents.
- `SidecarTranscriptionEngine` and `sidecar.py`: own subprocess lifetime, model downloads, and JSONLines protocol ordering.
- `SettingsStore`: stores local recent transcript history.

## Code Style

Match the style of the existing files: Swift concurrency with `@MainActor`, `ObservableObject` state, no third-party Swift dependencies. Python sidecar code follows the conventions in `sidecar.py` (stdlib + MLX only, JSONLines protocol, `emit()` for all stdout output).

## Pull Requests

PRs are welcome. Please:
- Keep changes focused — one concern per PR.
- Run the app build and unit tests before submitting.
- Run the sidecar smoke test before submitting.
- Update README, packaging docs, and license/dependency notes when changing permissions, model IDs, sidecar dependencies, or distribution behavior.
- Add or update doc comments for any new public API.
