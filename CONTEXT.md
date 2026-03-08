# Magic Voice — Domain Glossary

**Magic Voice** — the product name for this macOS menu-bar voice dictation app. The canonical machine name is `magic-voice`, used for the source folder, Xcode target, Xcode scheme, and bundle identifier (`ai.arailabs.magic-voice`).

**Activation key** — the modifier key that drives dictation gestures. It defaults to `fn` and can be changed in Settings to right Command or right Option; timing stays fixed inside `HotkeyGestureMachine`.

**TranscriptionEngine** — the backend-neutral seam the recording pipeline depends on for speech-to-text: callers `startSession` (model + language), `feedAudio` 16 kHz mono float32 chunks, then `finishSession`/`cancelSession`, receiving a single `TranscriptionEvent` stream (`.ready` / `.partial` / `.final` / `.failed`) through one handler. Every engine is stream-in/stream-out; non-streaming backends adapt inside their adapter so callers never branch on capability. `SidecarTranscriptionEngine` is the production adapter (wraps the Sidecar); `FakeTranscriptionEngine` is a scripted test double.

**Sidecar runtime** — the launch environment for the Python Sidecar, resolved through `SidecarRuntimeLocator`. `DevelopmentUvLocator` preserves the developer workflow (`uv` first, `python3` fallback) and reports `.needsInstall` with an actionable message when no runtime is present; `BundledRuntimeLocator` marks the future packaged-runtime adapter.

**Sidecar** — the Python subprocess (`sidecar/sidecar.py`) that the Swift app launches on startup, wrapped by the `SidecarTranscriptionEngine` adapter. It loads the Nemotron MLX model and communicates with the app over stdin/stdout using a JSONLines protocol (`start_stream` / `audio_chunk` / `finish_stream` / `done`).

**Injection** — the act of placing the final transcript into the frontmost app's focused text field. Two named adapters sit behind the `TextInjecting` protocol: `AccessibilityInjector` (primary — writes to `kAXSelectedTextAttribute`) and `ClipboardPasteInjector` (fallback — overwrites the clipboard and simulates ⌘V, then restores the original clipboard contents). `FallbackInjector` owns the policy: try AX, then clipboard. Every attempt returns an `InjectionResult` carrying which adapter ran (`InjectionAdapter`: `.accessibility` / `.clipboardPaste` / `.none`), a success flag, the skip/failure reason when AX was bypassed, and the injected text (retained so a future retract/retype feature can reference what was inserted). `TextInjector` is the `ObservableObject` facade that the rest of the app wires to; it exposes `lastResult: InjectionResult?` alongside the legacy `lastMethod`.

**Gesture machine** — the pure hotkey state machine (`HotkeyGestureMachine`) that converts activation-key down/up/tick inputs into dictation intents. Timing constants are fixed inside the machine: 0.28 s for hold detection and 0.3 s for the double-tap window.

**Dictation session** — the main orchestrator that owns a gesture machine and coordinates audio capture, pre-roll buffering, transcription events, final text injection, and the notch overlay. It starts capture as soon as a possible dictation gesture begins, buffers early audio until the engine is ready, and injects only the final transcript.

**Notch overlay** — a floating transparent window positioned near the camera housing (notch area) on supported MacBook models. It shows a compact recording indicator while the microphone is active, without occupying Dock or menu bar space beyond the normal menu bar icon.

**Status model** — pure derivation (`MenuBarStatusModel`) of the menu bar's status word, glyph state, and health banner from permission, engine, and session state. Views render its output and contain no health logic of their own.

**Health banner** — the single place "dictation isn't working" surfaces — a conditional banner at the top of the popover covering missing permissions (first priority) and engine-unavailable states.

## Design principles

- **Opinionated defaults over configuration.** Every interaction should feel weighed and thought through; we do not expose tuning knobs (timing windows, thresholds) as settings. The few settings that exist are identity-level choices (which key activates dictation, which model/language) — not behaviour tuning.
- **Streaming is the contract.** Engines stream audio in and transcript events out; engines that can't stream adapt internally. Callers never branch on engine capability.
- **Live feedback in the overlay, one clean insertion in the document.** The notch overlay shows the live transcript while recording; the target app receives a single final injection. Streaming injection into the target app returns only once injected text can be revised/retracted (see backlog: revisable streaming injection).
