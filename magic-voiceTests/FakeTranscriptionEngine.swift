//
//  FakeTranscriptionEngine.swift
//  magic-voiceTests
//
//  Magic Voice — a scripted `TranscriptionEngine` for driving the recording
//  pipeline in tests without launching the Python sidecar. It records the calls
//  it receives and replays a configurable script of events on demand.
//

import Foundation
@testable import Magic_Voice

@MainActor
final class FakeTranscriptionEngine: ObservableObject, TranscriptionEngine {

    // MARK: TranscriptionEngine observable state
    @Published private(set) var engineState: TranscriptionEngineState = .idle
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastErrorReason: String?

    // MARK: Scripting

    /// Events to deliver, in order, when `finishSession()` is called. Events
    /// before that (e.g. `.ready`, `.partial`) are delivered as the script
    /// chooses via `emitOnStart` / `emitOnFeed`.
    var finishScript: [TranscriptionEvent] = [.final(transcript: "scripted transcript")]
    /// Events delivered synchronously at the end of `startSession`.
    var startScript: [TranscriptionEvent] = [.ready]

    // MARK: Recorded interactions
    private(set) var startSessionCount = 0
    private(set) var fedAudio: [Data] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var receivedEvents: [TranscriptionEvent] = []

    private var onEvent: (@MainActor (TranscriptionEvent) -> Void)?
    private var cancelled = false

    // MARK: Streaming session

    func startSession(
        model: STTModel,
        language: String,
        onEvent: @escaping @MainActor (TranscriptionEvent) -> Void
    ) {
        startSessionCount += 1
        cancelled = false
        lastTranscript = ""
        lastErrorReason = nil
        engineState = .transcribing
        self.onEvent = onEvent
        for event in startScript {
            deliver(event)
        }
    }

    func feedAudio(_ data: Data) {
        guard !cancelled else { return }
        fedAudio.append(data)
    }

    func finishSession() {
        finishCount += 1
        guard !cancelled else { return }
        for event in finishScript {
            deliver(event)
        }
        engineState = .ready
        onEvent = nil
    }

    func cancelSession() {
        cancelCount += 1
        cancelled = true
        onEvent = nil
        engineState = .idle
    }

    // MARK: Engine lifecycle

    func startEngine(model: STTModel, language: String) {
        engineState = .ready
    }

    func stopEngine() {
        engineState = .idle
    }

    func restartEngine(model: STTModel, language: String) {
        engineState = .ready
    }

    // MARK: Helpers

    private func deliver(_ event: TranscriptionEvent) {
        guard !cancelled else { return }
        receivedEvents.append(event)
        switch event {
        case let .partial(_, fullTranscript):
            lastTranscript = fullTranscript
        case let .final(transcript):
            lastTranscript = transcript
        case let .failed(reason):
            lastErrorReason = reason
        case .ready:
            break
        }
        onEvent?(event)
    }
}
