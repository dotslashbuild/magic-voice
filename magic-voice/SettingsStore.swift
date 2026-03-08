//
//  SettingsStore.swift
//  magic-voice
//
//  Magic Voice — persistent user settings and transcription history.
//

import Combine
import Foundation
import SwiftUI

enum STTModel: String, CaseIterable, Identifiable {
    case nemotronStreaming06B = "nemotron-3.5-asr-streaming-0.6b"
    case nemotronStreaming06B8Bit = "nemotron-3.5-asr-streaming-0.6b-8bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nemotronStreaming06B:     return "Nemotron Streaming 0.6B"
        case .nemotronStreaming06B8Bit: return "Nemotron Streaming 0.6B 8-bit"
        }
    }

    var subtitle: String {
        switch self {
        case .nemotronStreaming06B:     return "Best local streaming quality"
        case .nemotronStreaming06B8Bit: return "Lower memory, slightly lower quality"
        }
    }

    var hubID: String {
        switch self {
        case .nemotronStreaming06B:     return "mlx-community/nemotron-3.5-asr-streaming-0.6b"
        case .nemotronStreaming06B8Bit: return "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
        }
    }
}

enum TriggerMode: String {
    case idle
    case pushToTalk
    case toggle
}

struct TranscriptionEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), text: String, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}

// UserDefaults keys written by SettingsStore (must remain stable across releases):
//   "selectedModel"        – STTModel raw value string
//   "language"             – String, e.g. "auto", "en", "es", "fr", "de"
//   "launchAtLogin"        – Bool
//   "activationKey"        – ActivationKey raw value string
//   "selectedMicrophoneID" – String, AVCaptureDevice uniqueID or "auto"
//   "historyCount"         – Int, maximum number of history entries retained
//   "transcriptionHistory" – Data, JSON-encoded [TranscriptionEntry]

@MainActor
final class SettingsStore: ObservableObject {

    // MARK: – Injected storage

    private let defaults: UserDefaults

    // MARK: – Published settings (persisted via defaults on write)

    @Published var selectedModelRaw: String {
        didSet { defaults.set(selectedModelRaw, forKey: Keys.selectedModel) }
    }
    @Published var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
    @Published var activationKeyRaw: String {
        didSet { defaults.set(activationKeyRaw, forKey: Keys.activationKey) }
    }
    @Published var selectedMicrophoneID: String {
        didSet { defaults.set(selectedMicrophoneID, forKey: Keys.selectedMicrophoneID) }
    }
    @Published var historyCount: Int {
        didSet { defaults.set(historyCount, forKey: Keys.historyCount) }
    }

    @Published private(set) var history: [TranscriptionEntry] = []

    // MARK: – Derived

    var selectedModel: STTModel {
        get { STTModel(rawValue: selectedModelRaw) ?? .nemotronStreaming06B }
        set { selectedModelRaw = newValue.rawValue }
    }

    var activationKey: ActivationKey {
        get { ActivationKey(rawValue: activationKeyRaw) ?? .function }
        set { activationKeyRaw = newValue.rawValue }
    }

    // MARK: – Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Read persisted values, falling back to the same defaults as before.
        // UserDefaults returns 0 for missing Double/Bool/Int keys, so we guard
        // with object(forKey:) != nil before reading typed accessors.
        self.selectedModelRaw      = defaults.string(forKey: Keys.selectedModel) ?? STTModel.nemotronStreaming06B.rawValue
        self.language              = defaults.string(forKey: Keys.language) ?? "auto"
        self.launchAtLogin         = defaults.object(forKey: Keys.launchAtLogin)         != nil ? defaults.bool(forKey: Keys.launchAtLogin) : false
        self.activationKeyRaw      = defaults.string(forKey: Keys.activationKey) ?? ActivationKey.function.rawValue
        self.selectedMicrophoneID  = defaults.string(forKey: Keys.selectedMicrophoneID) ?? AudioInputDevice.autoID
        self.historyCount          = defaults.object(forKey: Keys.historyCount)          != nil ? defaults.integer(forKey: Keys.historyCount) : 10

        loadHistory()
    }

    // MARK: – History

    func appendHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.insert(TranscriptionEntry(text: trimmed), at: 0)
        if history.count > historyCount {
            history = Array(history.prefix(historyCount))
        }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: Keys.transcriptionHistory),
              let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data) else {
            return
        }
        history = decoded
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Keys.transcriptionHistory)
    }

    // MARK: – Key constants

    private enum Keys {
        static let selectedModel         = "selectedModel"
        static let language              = "language"
        static let launchAtLogin         = "launchAtLogin"
        static let activationKey         = "activationKey"
        static let selectedMicrophoneID  = "selectedMicrophoneID"
        static let historyCount          = "historyCount"
        static let transcriptionHistory  = "transcriptionHistory"
    }
}
