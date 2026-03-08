//
//  TranscriptionEngineTests.swift
//  magic-voiceTests
//
//  Magic Voice — drives the scripted FakeTranscriptionEngine through a full
//  start → feed → finish session and asserts the event contract: ordering,
//  final-transcript delivery, and that cancel stops delivery.
//

import Foundation
import Testing
@testable import Magic_Voice

@MainActor
struct TranscriptionEngineTests {

    @Test
    func sessionDeliversReadyPartialsThenFinalInOrder() {
        let engine = FakeTranscriptionEngine()
        engine.startScript = [.ready]
        engine.finishScript = [
            .partial(chunk: "Hello", fullTranscript: "Hello"),
            .partial(chunk: " world", fullTranscript: "Hello world"),
            .final(transcript: "Hello world")
        ]

        var observed: [TranscriptionEvent] = []
        engine.startSession(model: .nemotronStreaming06B, language: "en") { event in
            observed.append(event)
        }

        engine.feedAudio(Data([0, 1, 2]))
        engine.feedAudio(Data([3, 4, 5]))
        engine.finishSession()

        #expect(observed == [
            .ready,
            .partial(chunk: "Hello", fullTranscript: "Hello"),
            .partial(chunk: " world", fullTranscript: "Hello world"),
            .final(transcript: "Hello world")
        ])
        #expect(engine.fedAudio.count == 2)
        #expect(engine.lastTranscript == "Hello world")
        #expect(engine.engineState == .ready)
    }

    @Test
    func finalTranscriptIsDeliveredExactlyOnce() {
        let engine = FakeTranscriptionEngine()
        engine.finishScript = [.final(transcript: "done")]

        var finals: [String] = []
        engine.startSession(model: .nemotronStreaming06B, language: "en") { event in
            if case let .final(transcript) = event { finals.append(transcript) }
        }
        engine.finishSession()

        #expect(finals == ["done"])
    }

    @Test
    func cancelStopsEventDelivery() {
        let engine = FakeTranscriptionEngine()
        engine.startScript = [.ready]
        engine.finishScript = [.final(transcript: "should not arrive")]

        var observed: [TranscriptionEvent] = []
        engine.startSession(model: .nemotronStreaming06B, language: "en") { event in
            observed.append(event)
        }

        engine.cancelSession()
        engine.feedAudio(Data([9]))
        engine.finishSession()

        #expect(observed == [.ready])
        #expect(engine.fedAudio.isEmpty)
        #expect(engine.engineState == .idle)
    }

    @Test
    func failedEventCarriesReason() {
        let engine = FakeTranscriptionEngine()
        engine.finishScript = [.failed(reason: "engine unavailable: no model")]

        var observed: [TranscriptionEvent] = []
        engine.startSession(model: .nemotronStreaming06B, language: "en") { event in
            observed.append(event)
        }
        engine.finishSession()

        #expect(observed.contains(.failed(reason: "engine unavailable: no model")))
        #expect(engine.lastErrorReason == "engine unavailable: no model")
    }
}
