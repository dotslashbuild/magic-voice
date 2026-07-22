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
    @StateObject private var runtimeProvisioner: ManagedRuntimeProvisioner
    @StateObject private var loginItemController: LoginItemController
    @StateObject private var firstRunSetupController: FirstRunSetupController
    private let smokeLaunchMode: SidecarSmokeLaunchMode?
    private let isProcessSupervisorSmoke: Bool

    init() {
        let smokeLaunchMode = parseSidecarSmokeLaunchMode(
            arguments: ProcessInfo.processInfo.arguments
        )
        self.smokeLaunchMode = smokeLaunchMode
        self.isProcessSupervisorSmoke = parseProcessSupervisorHostDeathSmokeRequest(
            arguments: ProcessInfo.processInfo.arguments
        ) != nil
        let settings = SettingsStore()
        let notchManager = NotchWindowManager()
        let permissionController = PermissionController()
        let audioCaptureManager = AudioCaptureManager(permissionController: permissionController)
        audioCaptureManager.selectedInputDeviceID = settings.selectedMicrophoneID
        let textInjector = TextInjector(permissionController: permissionController)
        let transcriptionEngine = SidecarTranscriptionEngine()
        let runtimeProvisioner = ManagedRuntimeProvisioner()
        let firstRunSetupController = FirstRunSetupController(
            settings: settings,
            permissionController: permissionController,
            engine: transcriptionEngine,
            runtimeProvisioner: runtimeProvisioner
        )
        let dictationSession = DictationSession(
            settings: settings,
            notchManager: notchManager,
            permissionController: permissionController,
            audioCaptureManager: audioCaptureManager,
            textInjector: textInjector,
            transcriptionEngine: transcriptionEngine
        )
        firstRunSetupController.attach(dictationSession: dictationSession)

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
        _runtimeProvisioner = StateObject(wrappedValue: runtimeProvisioner)
        _firstRunSetupController = StateObject(wrappedValue: firstRunSetupController)
        _dictationSession = StateObject(wrappedValue: dictationSession)

        appDelegate.installApplicationTerminationHandler { [weak transcriptionEngine] in
            await transcriptionEngine?.shutDownForApplicationTermination()
        }

        guard smokeLaunchMode == nil, !isProcessSupervisorSmoke else { return }

        Task { @MainActor in
            if runtimeProvisioner.requiresProvisioning {
                let result = await runtimeProvisioner.provision()
                guard result == .provisioned || result == .alreadyProvisioned else {
                    dictationSession.startHotkeyMonitoringOnLaunch()
                    return
                }
            }
            firstRunSetupController.evaluate()
            dictationSession.startHotkeyMonitoringOnLaunch()
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(smokeLaunchMode == nil && !isProcessSupervisorSmoke)) {
            MenuBarView()
                .environmentObject(settings)
                .environmentObject(notchManager)
                .environmentObject(permissionController)
                .environmentObject(audioCaptureManager)
                .environmentObject(dictationSession)
                .environmentObject(textInjector)
                .environmentObject(transcriptionEngine)
                .environmentObject(runtimeProvisioner)
                .environmentObject(firstRunSetupController)
        } label: {
            Image(nsImage: MenuBarGlyph.image(for: MenuBarStatusModel.glyph(
                notchActive: notchManager.state != .collapsed,
                monitoringEnabled: dictationSession.hotkeyMonitoringEnabled,
                setupPaused: transcriptionEngine.engineState == .loadingModel
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
    private let runtimeProvisioner: ManagedRuntimeProvisioner
    private weak var dictationSession: DictationSession?
    private var setupModelInFlight: STTModel?
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: SettingsStore,
        permissionController: PermissionController,
        engine: SidecarTranscriptionEngine,
        runtimeProvisioner: ManagedRuntimeProvisioner
    ) {
        self.settings = settings
        self.permissionController = permissionController
        self.engine = engine
        self.runtimeProvisioner = runtimeProvisioner

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

        runtimeProvisioner.$state
            .dropFirst()
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
    }

    func attach(dictationSession: DictationSession) {
        self.dictationSession = dictationSession
    }

    func evaluate() {
        markCompletedSetupIfNeeded()

        guard runtimeProvisioner.state == .ready else {
            isSettingUp = false
            updateHotkeySuspension()
            return
        }

        let model = settings.selectedModel

        guard permissionController.allRequiredPermissionsGranted else {
            isSettingUp = setupModelInFlight != nil && engine.engineState == .loadingModel
            updateHotkeySuspension()
            return
        }

        if settings.isSetupComplete(for: model) {
            if let setupModelInFlight, setupModelInFlight != model {
                isSettingUp = engine.engineState == .loadingModel
                updateHotkeySuspension()
                return
            }
            if engine.engineState == .loadingModel {
                isSettingUp = true
                updateHotkeySuspension()
                return
            }

            setupModelInFlight = nil
            isSettingUp = false
            updateHotkeySuspension()
            if engine.engineState == .idle {
                engine.startEngine(model: model, language: settings.language)
            }
            return
        }

        if engine.engineState == .loadingModel {
            isSettingUp = true
            updateHotkeySuspension()
            return
        }

        guard engine.engineState != .unavailable else {
            isSettingUp = false
            updateHotkeySuspension()
            return
        }

        setupModelInFlight = model
        isSettingUp = true
        updateHotkeySuspension()
        engine.downloadModel(model: model, language: settings.language)
    }

    func downloadSelectedModel() {
        guard runtimeProvisioner.state == .ready else { return }

        guard engine.engineState != .loadingModel else {
            isSettingUp = setupModelInFlight != nil
            updateHotkeySuspension()
            return
        }

        setupModelInFlight = settings.selectedModel
        isSettingUp = true
        updateHotkeySuspension()
        engine.downloadModel(model: settings.selectedModel, language: settings.language)
    }

    func retry() {
        guard runtimeProvisioner.state == .ready,
              permissionController.allRequiredPermissionsGranted else { return }
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

    private func updateHotkeySuspension() {
        if engine.engineState == .loadingModel {
            dictationSession?.suspendHotkeysForSetup()
        } else if settings.isSetupComplete(for: settings.selectedModel) {
            dictationSession?.resumeHotkeysAfterSetupIfNeeded()
        }
    }
}
