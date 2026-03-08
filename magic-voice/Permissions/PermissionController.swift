//
//  PermissionController.swift
//  magic-voice
//
//  Magic Voice — dynamic TCC checks and request actions.
//

import AppKit
import ApplicationServices
import AVFoundation
import Combine

@MainActor
final class PermissionController: ObservableObject {
    @Published private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    @Published private(set) var isPolling = false

    private var pollingTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    var allRequiredPermissionsGranted: Bool {
        PermissionKind.allCases.allSatisfy { status(for: $0).isGranted }
    }

    init() {
        refresh()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        pollingTask?.cancel()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .unknown
    }

    func refresh() {
        var updatedStatuses: [PermissionKind: PermissionStatus] = [:]
        for kind in PermissionKind.allCases {
            updatedStatuses[kind] = diagnose(kind)
        }
        statuses = updatedStatuses

        if allRequiredPermissionsGranted {
            stopPolling()
        }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            requestMicrophoneAccess()
        case .accessibility:
            requestAccessibilityAccess()
        }
    }

    func openSettings(for kind: PermissionKind) {
        guard let url = settingsURL(for: kind) else { return }
        NSWorkspace.shared.open(url)
    }

    func startPolling() {
        pollingTask?.cancel()
        isPolling = true
        pollingTask = Task { [weak self] in
            for _ in 0..<60 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self?.refresh()
                }

                if await MainActor.run(body: { self?.allRequiredPermissionsGranted == true }) {
                    break
                }
            }

            await MainActor.run {
                self?.stopPolling()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    private func diagnose(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            return microphoneStatus()
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .needsAccess
        }
    }

    private func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .needsAccess
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    private func requestMicrophoneAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            openSettings(for: .microphone)
            startPolling()
            return
        }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.startPolling()
            }
        }
    }

    private func requestAccessibilityAccess() {
        if !AXIsProcessTrusted() {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        openSettings(for: .accessibility)
        startPolling()
    }

    private func settingsURL(for kind: PermissionKind) -> URL? {
        let path: String
        switch kind {
        case .microphone:
            path = "Privacy_Microphone"
        case .accessibility:
            path = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)")
    }
}
