//
//  MagicVoiceApp.swift
//  magic-voice
//
//  Magic Voice — app entry point. Lives in the menu bar only.
//

import SwiftUI

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

    init() {
        let settings = SettingsStore()
        let notchManager = NotchWindowManager()
        let permissionController = PermissionController()
        let audioCaptureManager = AudioCaptureManager(permissionController: permissionController)
        audioCaptureManager.selectedInputDeviceID = settings.selectedMicrophoneID
        let textInjector = TextInjector(permissionController: permissionController)
        let transcriptionEngine = SidecarTranscriptionEngine()
        let runtimeProvisioner = ManagedRuntimeProvisioner()
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
        _runtimeProvisioner = StateObject(wrappedValue: runtimeProvisioner)
        _dictationSession = StateObject(wrappedValue: dictationSession)

        Task { @MainActor in
            if runtimeProvisioner.requiresProvisioning {
                let result = await runtimeProvisioner.provision()
                guard result == .provisioned || result == .alreadyProvisioned else {
                    dictationSession.startHotkeyMonitoringOnLaunch()
                    return
                }
            }
            transcriptionEngine.startEngine(
                model: settings.selectedModel,
                language: settings.language
            )
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
                .environmentObject(runtimeProvisioner)
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
        }
    }
}
