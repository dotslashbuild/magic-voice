//
//  TranscriptionEngine.swift
//  magic-voice
//
//  Magic Voice — the seam between the recording pipeline and any speech-to-text
//  backend. Every engine is stream-in / stream-out: callers start a streaming
//  session, feed 16 kHz mono float32 audio chunks, and await a single final
//  transcript. Engines that cannot stream (non-streaming input or output) adapt
//  INSIDE their adapter — callers never branch on engine capability.
//
//  The vocabulary here is deliberately backend-neutral: no processes, no
//  JSONLines, no model-hub paths. A sidecar, a Whisper binary, a cloud API, or a
//  Core ML model all conform to the same contract.
//

import Foundation

/// A single event emitted by a `TranscriptionEngine` during a streaming
/// session, delivered through one handler so a future `AsyncStream` migration
/// wraps a single channel.
enum TranscriptionEvent: Equatable {
    /// The engine has accepted the session and is ready to receive audio.
    case ready
    /// An incremental transcript update. `chunk` is the newly recognised text;
    /// `fullTranscript` is the cumulative transcript so far. Engines that cannot
    /// emit partials simply never send this case.
    case partial(chunk: String, fullTranscript: String)
    /// The session finished successfully with its final transcript.
    case final(transcript: String)
    /// The session could not complete. `reason` is human-readable.
    case failed(reason: String)
}

/// The lifecycle state of a transcription engine, expressed without
/// backend-specific terminology so the debug UI can observe it generically.
enum TranscriptionEngineState: String {
    /// The engine has not been started, or has been stopped.
    case idle = "Idle"
    /// The engine is warming up (launching, connecting).
    case starting = "Starting"
    /// The engine is loading its model into memory.
    case loadingModel = "Loading model"
    /// The engine is started and ready to accept sessions.
    case ready = "Ready"
    /// A streaming or file session is in flight.
    case transcribing = "Transcribing"
    /// The engine cannot be used; see `lastErrorReason` for why.
    case unavailable = "Unavailable"
}

/// The contract the recording pipeline depends on instead of any concrete
/// backend. Conformers are `@MainActor` `ObservableObject`s so SwiftUI can
/// observe their published state.
@MainActor
protocol TranscriptionEngine: ObservableObject {

    // MARK: Observable state

    /// Coarse lifecycle/activity state, safe to surface in UI.
    var engineState: TranscriptionEngineState { get }
    /// The most recent transcript produced (streaming or file), for display.
    var lastTranscript: String { get }
    /// A human-readable reason the engine is unavailable or a session failed,
    /// or `nil` when healthy.
    var lastErrorReason: String? { get }

    // MARK: Engine lifecycle (debug surface)

    /// Bring the engine up for the given model + language without starting a
    /// session. Idempotent when already up with the same configuration.
    func startEngine(model: STTModel, language: String)
    /// Tear the engine down and release its resources.
    func stopEngine()
    /// Restart the engine for the given model + language.
    func restartEngine(model: STTModel, language: String)

    // MARK: Streaming session (stream-in / stream-out)

    /// Begin a streaming session. Events are delivered through `onEvent` on the
    /// main actor: `.ready` once audio can be fed, zero or more `.partial`
    /// updates, and exactly one terminal `.final` or `.failed`.
    func startSession(
        model: STTModel,
        language: String,
        onEvent: @escaping @MainActor (TranscriptionEvent) -> Void
    )
    /// Feed a chunk of 16 kHz mono float32 audio to the active session.
    func feedAudio(_ data: Data)
    /// Signal end-of-audio; the engine will emit its terminal event.
    func finishSession()
    /// Abandon the active session; no further events are delivered.
    func cancelSession()
}
