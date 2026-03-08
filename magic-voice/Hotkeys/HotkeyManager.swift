//
//  HotkeyManager.swift
//  magic-voice
//
//  Magic Voice — AppKit global/local modifier-key monitoring.
//

import AppKit
import Carbon.HIToolbox

enum ActivationKey: String, CaseIterable, Identifiable {
    case function = "fn"
    case rightCommand = "rightCommand"
    case rightOption = "rightOption"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .function:
            return "fn"
        case .rightCommand:
            return "Right Command"
        case .rightOption:
            return "Right Option"
        }
    }
}

struct ActivationKeyTransition: Equatable {
    enum Phase {
        case down
        case up
    }

    let phase: Phase
}

@MainActor
final class HotkeyManager {
    var activationKey: ActivationKey = .function {
        didSet {
            guard activationKey != oldValue else { return }
            isActivationKeyDown = false
        }
    }

    var onActivationKeyDown: (() -> Void)?
    var onActivationKeyUp: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isActivationKeyDown = false

    var isMonitoring: Bool {
        globalMonitor != nil || localMonitor != nil
    }

    func start() {
        guard !isMonitoring else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isActivationKeyDown = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let transition = Self.transition(
            for: activationKey,
            eventKeyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            wasPressed: isActivationKeyDown
        ) else {
            return
        }

        switch transition.phase {
        case .down:
            isActivationKeyDown = true
            onActivationKeyDown?()
        case .up:
            isActivationKeyDown = false
            onActivationKeyUp?()
        }
    }

    nonisolated static func transition(
        for activationKey: ActivationKey,
        eventKeyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasPressed: Bool
    ) -> ActivationKeyTransition? {
        guard eventKeyCode == activationKey.keyCode else { return nil }

        let isPressed = modifierFlags.contains(activationKey.modifierFlag)
        if isPressed && !wasPressed {
            return ActivationKeyTransition(phase: .down)
        }
        if !isPressed && wasPressed {
            return ActivationKeyTransition(phase: .up)
        }
        return nil
    }
}

private extension ActivationKey {
    nonisolated var keyCode: UInt16 {
        switch self {
        case .function:
            return UInt16(kVK_Function)
        case .rightCommand:
            return UInt16(kVK_RightCommand)
        case .rightOption:
            return UInt16(kVK_RightOption)
        }
    }

    nonisolated var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .function:
            return .function
        case .rightCommand:
            return .command
        case .rightOption:
            return .option
        }
    }
}
