# Magic Voice Packaging Checklist

This project is a direct-distribution macOS app. It should not be shipped with App Sandbox enabled because global hotkeys, Accessibility text insertion, clipboard paste fallback, and the Python sidecar need process and system API access that are not App Store sandbox-friendly.

The first public easy-install release should ship as a signed, notarized `.dmg` with the standard drag-to-Applications flow. Do not use a `.pkg` installer unless a future release needs privileged installation or preinstall steps.

The first release should use manual updates: users download a replacement `.dmg` from the website or GitHub Releases. Defer Sparkle or any other automatic updater until signing, notarization, and first-run setup are stable.

## Xcode Settings

- Product name/display name: `Magic Voice`
- Current project deployment target: macOS 26.2
- Intended public deployment target: verify before release and keep this file, README, and Xcode settings in sync
- First public easy-install release hardware target: Apple Silicon Macs only.
- App Sandbox: Off. The current project has no sandbox entitlement file.
- Hardened Runtime: enable before Developer ID distribution. The current project file does not declare a hardened-runtime setting.
- `LSUIElement`: `YES`
- `NSMicrophoneUsageDescription`: `Magic Voice uses your microphone to transcribe speech locally on your device.`
- `NSAppleEventsUsageDescription`: `Magic Voice uses Accessibility to insert transcribed text into the active text field.`

## Bundle Resources

Before public packaging, add these files to the app target's Copy Bundle Resources phase:

- `sidecar/sidecar.py`
- `sidecar/pyproject.toml`
- `sidecar/uv.lock`

The current project already includes `sidecar.py` and `pyproject.toml` as resources, but not `uv.lock`. The Swift sidecar launcher first looks in `Bundle.main` for `sidecar.py`, then falls back to the local source tree for developer builds. The managed runtime copies `sidecar.py`, `pyproject.toml`, and `uv.lock` together before launching `uv run --frozen`; packaged builds must include all three files or the sidecar can fail before transcription starts.

## Python Runtime

Developer builds resolve the sidecar launch plan through `SidecarRuntimeLocator`.
`DevelopmentUvLocator` currently uses `uv` from one of:

- `~/.local/bin/uv`
- `/opt/homebrew/bin/uv`
- `/usr/local/bin/uv`

If `uv` is missing, it falls back to common `python3` locations. That fallback is useful for local debugging only: it does not install or lock Python dependencies. Public builds should use a managed or bundled `uv` path so dependency resolution stays reproducible.

For the first public easy-install build, bundle a signed `uv` executable and let the app create a managed Python/venv under Application Support. This keeps the user-facing install path no-terminal while staying close to the current sidecar architecture. Fully bundling Python or replacing the sidecar with a native Swift/Core ML runtime can be revisited after the first public install path works.

Do not publish a binary until this decision is implemented and tested on a clean macOS account.

## Third-Party Licenses

Before publishing a source or binary release, add a license inventory for:

- Swift/macOS platform requirements.
- Python packages from `sidecar/pyproject.toml` and `sidecar/uv.lock`.
- The default Hugging Face model (`mlx-community/nemotron-3.5-asr-streaming-0.6b`) and the low-memory variant.
- `uv`, if bundled or installed by the app.

The repository license covers this project's source code. It does not automatically grant redistribution rights for downloaded models, Python packages, or bundled runtime tools.

## Privacy and System Side Effects

Release notes and onboarding should disclose:

- Audio and transcription run locally after model/dependency download.
- First run downloads Python dependencies and the selected STT model into Application Support rather than bundling the model inside the `.dmg`.
- During first-run setup, dictation should stay blocked behind one clear setup state until Python dependencies and the speech model are ready. Show percentage progress only if it is reliable; otherwise show an indeterminate setup state with failure and retry.
- The menu-bar status model should show setup explicitly as `Setting Up`, not `Ready`; permissions remain the highest-priority banner, setup is second, and ready appears only after the engine/model path is usable.
- First-run setup should start automatically after the required Microphone and Accessibility permissions are granted, with a visible failure and retry path instead of a separate setup button.
- Track setup completion per selected speech model using the model's stable identifier. Set the marker only after Python dependencies and the selected model download complete successfully; failed setup should leave the marker unset and show retry.
- If the user switches to a model without a completed setup marker, Magic Voice should re-enter the same setup flow for that model. Switching back to a model with a completed setup marker should not repeat setup.
- The first-run path should use the default speech model without asking the user to choose. Keep alternate models in Settings for later, not in the install flow.
- First-run guidance should live inside the existing menu-bar popover as a compact checklist/status flow, not in a separate welcome window.
- The fallback injector temporarily replaces the clipboard and restores it after paste.
- The fn activation-key path temporarily changes the user-wide `com.apple.HIToolbox AppleFnUsageType` preference to avoid Apple Dictation conflicts, then restores the saved value on normal release and next-launch recovery.

## Signing and Notarization

Use a Developer ID Application certificate for distribution outside the App Store.

```sh
xcodebuild -project magic-voice.xcodeproj -scheme magic-voice -configuration Release archive
```

After archiving, export a Developer ID app, then notarize and staple the exported `.app` or `.dmg` with `notarytool` and `stapler`.

## Smoke Test Before Shipping

- Launch app: no Dock icon, menu bar icon appears.
- Permissions: Microphone and Accessibility show granted.
- Hotkey: double-tap the selected activation key starts/stops toggle recording; holding it runs push-to-talk.
- Hotkey: verify global activation from another app on real hardware with Accessibility granted.
- fn key: if using the fn activation key, verify the original Apple Dictation / input-source behavior is restored after pause, quit, force quit plus relaunch, and crash recovery.
- Audio: saved recording is `16k-mono-f32.wav` and plays back clearly.
- STT: sidecar starts with selected Nemotron model and returns transcript.
- STT: model download progress does not hang and errors surface clearly.
- STT: canceling a recording does not poison the next recording session.
- Injection: delayed and real dictation injection preserve the previous clipboard.
