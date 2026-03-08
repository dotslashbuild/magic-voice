//
//  SettingsStoreTests.swift
//  magic-voiceTests
//
//  Magic Voice — SettingsStore persistence round-trip (carry-over from W1-1).
//  Verifies values land under the documented UserDefaults keys, survive a
//  reconstruction from the same suite, and that history is persisted.
//

import Foundation
import Testing
@testable import Magic_Voice

@MainActor
struct SettingsStoreTests {

    @Test
    func mutatedSettingsPersistUnderStableKeysAndRoundTrip() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: suite)
        store.language = "fr"
        store.selectedModel = .nemotronStreaming06B8Bit
        store.activationKey = .rightCommand
        store.selectedMicrophoneID = "test-microphone-id"

        // Values land under the documented, unchanged key names.
        #expect(suite.string(forKey: "language") == "fr")
        #expect(suite.string(forKey: "selectedModel") == STTModel.nemotronStreaming06B8Bit.rawValue)
        #expect(suite.string(forKey: "activationKey") == ActivationKey.rightCommand.rawValue)
        #expect(suite.string(forKey: "selectedMicrophoneID") == "test-microphone-id")

        // A second store built from the same suite round-trips the values.
        let reloaded = SettingsStore(defaults: suite)
        #expect(reloaded.language == "fr")
        #expect(reloaded.selectedModel == .nemotronStreaming06B8Bit)
        #expect(reloaded.activationKey == .rightCommand)
        #expect(reloaded.selectedMicrophoneID == "test-microphone-id")
    }

    @Test
    func appendedHistorySurvivesReconstruction() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: suite)
        store.appendHistory("hello")

        let reloaded = SettingsStore(defaults: suite)
        #expect(reloaded.history.contains { $0.text == "hello" })
    }
}
