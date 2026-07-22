//
//  DictationSession.swift
//  magic-voice
//
//  Magic Voice — coordinates hotkey gestures, audio capture, transcription,
//  text injection, and the notch overlay.
//

import Combine
import Foundation

@MainActor
final class DictationSession: ObservableObject {
    @Published private(set) var triggerMode: TriggerMode = .idle
    @Published private(set) var hotkeyMonitoringEnabled = false
    @Published private(set) var lastHotkeyEventDescription = "Waiting for activation key"

    private let settings: SettingsStore
    private let notchManager: NotchWindowManager
    private let permissionController: PermissionController
    private let audioCaptureManager: AudioCaptureManager
    private let textInjector: TextInjector
    private let transcriptionEngine: any TranscriptionEngine
    private let activationKeyMonitor: ActivationKeyMonitor

    private var gestureMachine = HotkeyGestureMachine()
    private var pendingDecisionTask: Task<Void, Never>?
    private var pendingDecisionDeadline: TimeInterval?
    private var recordingSessionShouldInjectTranscript = true
    private var engineReadyForAudio = false
    private var finishWhenEngineReady = false
    private var setupSuspensionActive = false
    private var setupSuspensionShouldResume = false
    private var prerollBuffer = PrerollAudioBuffer()
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: SettingsStore,
        notchManager: NotchWindowManager,
        permissionController: PermissionController,
        audioCaptureManager: AudioCaptureManager,
        textInjector: TextInjector,
        transcriptionEngine: any TranscriptionEngine,
        activationKeyMonitor: ActivationKeyMonitor? = nil
    ) {
        self.settings = settings
        self.notchManager = notchManager
        self.permissionController = permissionController
        self.audioCaptureManager = audioCaptureManager
        self.textInjector = textInjector
        self.transcriptionEngine = transcriptionEngine
        let monitor = activationKeyMonitor ?? ActivationKeyMonitor(
            hotkeyManager: HotkeyManager(),
            permissionGate: permissionController,
            activationKeyProvider: { [settings] in settings.activationKey }
        )
        self.activationKeyMonitor = monitor

        monitor.onActivationKeyTransition = { [weak self] transition in
            switch transition {
            case .down:
                self?.handleFunctionKeyDown()
            case .up:
                self?.handleFunctionKeyUp()
            }
        }

        // Re-source the monitor's lifecycle state into this session's published
        // properties, which the UI observes.
        monitor.$isEnabled
            .assign(to: &$hotkeyMonitoringEnabled)
        monitor.$lastEventDescription
            .assign(to: &$lastHotkeyEventDescription)

        settings.$activationKeyRaw
            .dropFirst()
            .sink { [weak self] _ in
                self?.activationKeyDidChange()
            }
            .store(in: &cancellables)

        permissionController.$statuses
            .dropFirst()
            .sink { [weak self] _ in
                self?.activationKeyMonitor.enableIfPermitted()
            }
            .store(in: &cancellables)

        audioCaptureManager.$inputLevel
            .sink { [weak notchManager] level in
                notchManager?.pushAudioLevel(level)
            }
            .store(in: &cancellables)
    }

    deinit {
        pendingDecisionTask?.cancel()
    }

    func startHotkeyMonitoring() {
        activationKeyMonitor.enable()
    }

    func startHotkeyMonitoringOnLaunch() {
        // Intentionally uses enableIfPermitted (not enable) so that an explicit
        // user-pause from a previous session is honoured on relaunch. The "OnLaunch"
        // name describes *when* this is called, not that it unconditionally starts.
        activationKeyMonitor.enableIfPermitted(refreshPermissions: true)
    }

    func pauseHotkeyMonitoring() {
        activationKeyMonitor.pause()
        tearDownActiveGestureAndRecording(reason: "Stopped monitoring")
    }

    func toggleHotkeyMonitoring() {
        if hotkeyMonitoringEnabled {
            pauseHotkeyMonitoring()
        } else {
            startHotkeyMonitoring()
        }
    }

    func suspendHotkeysForSetup() {
        guard !setupSuspensionActive else { return }
        setupSuspensionActive = true
        setupSuspensionShouldResume = hotkeyMonitoringEnabled
        activationKeyMonitor.suspend(reason: "Setting up speech model")
        tearDownActiveGestureAndRecording(reason: "Setting up speech model")
    }

    func resumeHotkeysAfterSetupIfNeeded() {
        guard setupSuspensionActive else { return }
        let shouldResume = setupSuspensionShouldResume
        setupSuspensionActive = false
        setupSuspensionShouldResume = false
        guard shouldResume else { return }
        activationKeyMonitor.enableIfPermitted(refreshPermissions: true)
    }

    private func handleFunctionKeyDown() {
        lastHotkeyEventDescription = "\(settings.activationKey.displayName) down"
        apply(gestureMachine.keyDown(at: CFAbsoluteTimeGetCurrent()))
    }

    private func handleFunctionKeyUp() {
        let now = CFAbsoluteTimeGetCurrent()
        resolveOverdueGestureDeadline(at: now)
        pendingDecisionTask?.cancel()
        pendingDecisionDeadline = nil
        lastHotkeyEventDescription = "\(settings.activationKey.displayName) up"
        apply(gestureMachine.keyUp(at: now))
    }

    private func activationKeyDidChange() {
        // Reset the gesture timing driver this session owns; the monitor handles
        // retargeting and restarting the HotkeyManager.
        pendingDecisionTask?.cancel()
        pendingDecisionDeadline = nil
        _ = gestureMachine.reset()
        discardPreroll()
        activationKeyMonitor.activationKeyDidChange()
    }

    private func tearDownActiveGestureAndRecording(reason: String) {
        pendingDecisionTask?.cancel()
        pendingDecisionDeadline = nil
        _ = gestureMachine.reset()
        discardPreroll()
        if triggerMode != .idle {
            stopRecording(reason: reason, shouldInjectTranscript: false)
        }
    }

    private func handleGestureDeadline(at deadline: TimeInterval) {
        pendingDecisionDeadline = nil
        apply(gestureMachine.tick(at: deadline))
    }

    private func apply(_ output: HotkeyGestureMachine.Output) {
        scheduleDecisionIfNeeded(output.pendingDeadline)

        switch output.intent {
        case .none:
            break
        case .beginPreroll:
            beginPreroll()
        case .discardPreroll:
            discardPreroll()
        case .beginPushToTalk:
            startRecording(mode: .pushToTalk, reason: "Push-to-talk")
        case .beginToggle:
            startRecording(mode: .toggle, reason: "Toggle started")
        case .endSession:
            stopRecording(reason: triggerMode == .pushToTalk ? "Push-to-talk released" : "Toggle stopped")
        }
    }

    private func scheduleDecisionIfNeeded(_ deadline: TimeInterval?) {
        pendingDecisionTask?.cancel()
        pendingDecisionDeadline = deadline
        guard let deadline else { return }

        let delay = max(0, deadline - CFAbsoluteTimeGetCurrent())
        pendingDecisionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.handleGestureDeadline(at: deadline)
            }
        }
    }

    private func resolveOverdueGestureDeadline(at time: TimeInterval) {
        guard let deadline = pendingDecisionDeadline, deadline <= time else { return }
        pendingDecisionTask?.cancel()
        pendingDecisionTask = nil
        pendingDecisionDeadline = nil
        apply(gestureMachine.tick(at: time))
    }

    private func beginPreroll() {
        prerollBuffer.discard()
        engineReadyForAudio = false
        audioCaptureManager.onNormalizedAudioChunk = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handleAudioChunk(data)
            }
        }
        audioCaptureManager.startCapture()
        if let lastError = audioCaptureManager.lastError {
            lastHotkeyEventDescription = lastError
        }
    }

    private func discardPreroll() {
        prerollBuffer.discard()
        engineReadyForAudio = false
        finishWhenEngineReady = false
        if triggerMode == .idle {
            audioCaptureManager.stopCapture()
            audioCaptureManager.onNormalizedAudioChunk = nil
        }
    }

    private func handleAudioChunk(_ data: Data) {
        if engineReadyForAudio {
            transcriptionEngine.feedAudio(data)
        } else {
            prerollBuffer.append(data)
        }
    }

    private func startRecording(mode: TriggerMode, reason: String) {
        guard settings.isSetupComplete(for: settings.selectedModel) else {
            lastHotkeyEventDescription = "Setting up speech model"
            discardPreroll()
            return
        }

        guard audioCaptureManager.lastError == nil else {
            discardPreroll()
            return
        }

        triggerMode = mode
        lastHotkeyEventDescription = "Preparing speech model"
        recordingSessionShouldInjectTranscript = true
        engineReadyForAudio = false
        finishWhenEngineReady = false
        notchManager.transition(to: .active, transcript: "")

        transcriptionEngine.startSession(
            model: settings.selectedModel,
            language: settings.language
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready:
                guard self.triggerMode == mode || self.finishWhenEngineReady else { return }
                self.engineReadyForAudio = true
                for chunk in self.prerollBuffer.flush() {
                    self.transcriptionEngine.feedAudio(chunk)
                }
                if self.finishWhenEngineReady {
                    self.finishWhenEngineReady = false
                    self.lastHotkeyEventDescription = "Transcribing"
                    self.transcriptionEngine.finishSession()
                    return
                }
                self.lastHotkeyEventDescription = reason
            case let .partial(_, transcript):
                self.notchManager.updateTranscript(transcript)
            case let .final(transcript):
                self.handleCompletedTranscript(transcript)
            case let .failed(reason):
                self.handleFailedTranscript(reason)
            }
        }
    }

    private func stopRecording(reason: String, shouldInjectTranscript: Bool = true) {
        guard triggerMode != .idle else {
            discardPreroll()
            return
        }

        triggerMode = .idle
        lastHotkeyEventDescription = reason
        recordingSessionShouldInjectTranscript = shouldInjectTranscript
        audioCaptureManager.stopCapture()
        audioCaptureManager.onNormalizedAudioChunk = nil

        guard shouldInjectTranscript else {
            engineReadyForAudio = false
            finishWhenEngineReady = false
            prerollBuffer.discard()
            transcriptionEngine.cancelSession()
            notchManager.transition(to: .finished, transcript: "")
            return
        }

        guard engineReadyForAudio else {
            finishWhenEngineReady = true
            lastHotkeyEventDescription = "Preparing transcript"
            return
        }

        engineReadyForAudio = false
        finishWhenEngineReady = false
        prerollBuffer.discard()
        lastHotkeyEventDescription = "Transcribing"
        transcriptionEngine.finishSession()
    }

    private func handleCompletedTranscript(_ transcript: String) {
        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTranscript.isEmpty else {
            lastHotkeyEventDescription = "No transcript"
            notchManager.transition(to: .finished, transcript: "")
            return
        }

        lastHotkeyEventDescription = "Transcript ready"
        notchManager.transition(to: .finished, transcript: finalTranscript)
        settings.appendHistory(finalTranscript)
        if recordingSessionShouldInjectTranscript {
            textInjector.inject(finalTranscript)
        }
    }

    private func handleFailedTranscript(_ reason: String) {
        triggerMode = .idle
        engineReadyForAudio = false
        finishWhenEngineReady = false
        prerollBuffer.discard()
        audioCaptureManager.stopCapture()
        audioCaptureManager.onNormalizedAudioChunk = nil
        lastHotkeyEventDescription = reason
        notchManager.transition(to: .finished, transcript: "")
    }
}
