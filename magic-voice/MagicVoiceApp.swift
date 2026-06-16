//
//  MagicVoiceApp.swift
//  magic-voice
//
//  Magic Voice — app entry point. Lives in the menu bar only.
//

import SwiftUI
import Combine

@main
struct MagicVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var notchManager: NotchWindowManager
    @StateObject private var permissionController: PermissionController
    @StateObject private var audioCaptureManager: AudioCaptureManager
    @StateObject private var dictationSession: DictationSession
    @StateObject private var textInjector: TextInjector
    @StateObject private var transcriptionEngine: SidecarTranscriptionEngine
    @StateObject private var loginItemController: LoginItemController
    @StateObject private var firstRunSetupController: FirstRunSetupController

    init() {
        let settings = SettingsStore()
        let notchManager = NotchWindowManager()
        let permissionController = PermissionController()
        let audioCaptureManager = AudioCaptureManager(permissionController: permissionController)
        audioCaptureManager.selectedInputDeviceID = settings.selectedMicrophoneID
        let textInjector = TextInjector(permissionController: permissionController)
        let transcriptionEngine = SidecarTranscriptionEngine()
        let firstRunSetupController = FirstRunSetupController(
            settings: settings,
            permissionController: permissionController,
            engine: transcriptionEngine
        )
        let dictationSession = DictationSession(
            settings: settings,
            notchManager: notchManager,
            permissionController: permissionController,
            audioCaptureManager: audioCaptureManager,
            textInjector: textInjector,
            transcriptionEngine: transcriptionEngine
        )

        _settings = StateObject(wrappedValue: settings)
        _loginItemController = StateObject(wrappedValue: LoginItemController(
            settings: settings,
            service: MainAppLoginItemService()
        ))
        _notchManager = StateObject(wrappedValue: notchManager)
        _permissionController = StateObject(wrappedValue: permissionController)
        _audioCaptureManager = StateObject(wrappedValue: audioCaptureManager)
        _textInjector = StateObject(wrappedValue: textInjector)
        _transcriptionEngine = StateObject(wrappedValue: transcriptionEngine)
        _firstRunSetupController = StateObject(wrappedValue: firstRunSetupController)
        _dictationSession = StateObject(wrappedValue: dictationSession)

        Task { @MainActor in
            firstRunSetupController.evaluate()
            dictationSession.startHotkeyMonitoringOnLaunch()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(settings)
                .environmentObject(notchManager)
                .environmentObject(permissionController)
                .environmentObject(audioCaptureManager)
                .environmentObject(dictationSession)
                .environmentObject(textInjector)
                .environmentObject(transcriptionEngine)
                .environmentObject(firstRunSetupController)
        } label: {
            Image(nsImage: MenuBarGlyph.image(for: MenuBarStatusModel.glyph(
                notchActive: notchManager.state != .collapsed,
                monitoringEnabled: dictationSession.hotkeyMonitoringEnabled
            )))
            .accessibilityLabel("Magic Voice")
        }
        .menuBarExtraStyle(.window)

        Settings {
            TabView {
                GeneralSettingsTab()
                    .tabItem { Label("General", systemImage: "gearshape") }
                TranscriptionSettingsTab()
                    .tabItem { Label("Transcription", systemImage: "waveform") }
            }
            .environmentObject(settings)
            .environmentObject(transcriptionEngine)
            .environmentObject(firstRunSetupController)
        }
    }
}

@MainActor
final class FirstRunSetupController: ObservableObject {
    @Published private(set) var isSettingUp = false

    private let settings: SettingsStore
    private let permissionController: PermissionController
    private let engine: SidecarTranscriptionEngine
    private var setupModelInFlight: STTModel?
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: SettingsStore,
        permissionController: PermissionController,
        engine: SidecarTranscriptionEngine
    ) {
        self.settings = settings
        self.permissionController = permissionController
        self.engine = engine

        permissionController.$statuses
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        settings.$selectedModelRaw
            .dropFirst()
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        settings.$language
            .dropFirst()
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        engine.$engineState
            .dropFirst()
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        engine.$completedModelDownload
            .dropFirst()
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
    }

    func evaluate() {
        markCompletedSetupIfNeeded()

        let model = settings.selectedModel

        guard permissionController.allRequiredPermissionsGranted else {
            isSettingUp = setupModelInFlight != nil && engine.engineState == .loadingModel
            return
        }

        if settings.isSetupComplete(for: model) {
            if let setupModelInFlight, setupModelInFlight != model {
                isSettingUp = engine.engineState == .loadingModel
                return
            }
            if engine.engineState == .loadingModel {
                isSettingUp = true
                return
            }

            setupModelInFlight = nil
            isSettingUp = false
            if engine.engineState == .idle {
                engine.startEngine(model: model, language: settings.language)
            }
            return
        }

        if engine.engineState == .loadingModel {
            isSettingUp = true
            return
        }

        guard engine.engineState != .unavailable else {
            isSettingUp = false
            return
        }

        setupModelInFlight = model
        isSettingUp = true
        engine.downloadModel(model: model, language: settings.language)
    }

    func downloadSelectedModel() {
        guard engine.engineState != .loadingModel else {
            isSettingUp = setupModelInFlight != nil
            return
        }

        setupModelInFlight = settings.selectedModel
        isSettingUp = true
        engine.downloadModel(model: settings.selectedModel, language: settings.language)
    }

    func retry() {
        guard permissionController.allRequiredPermissionsGranted else { return }
        setupModelInFlight = nil
        isSettingUp = false
        engine.stopEngine()
        evaluate()
    }

    private func markCompletedSetupIfNeeded() {
        guard let completedModel = setupModelInFlight,
              engine.completedModelDownload?.model == completedModel else {
            return
        }

        settings.markSetupComplete(for: completedModel)
        setupModelInFlight = nil
        isSettingUp = false
    }
}
