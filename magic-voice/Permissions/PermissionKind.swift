//
//  PermissionKind.swift
//  magic-voice
//
//  Magic Voice — required macOS permission identifiers.
//

import Foundation

enum PermissionKind: CaseIterable, Identifiable {
    case microphone
    case accessibility

    var id: Self { self }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            return "Required to record your dictation."
        case .accessibility:
            return "Required to detect the activation key and insert text into the focused app."
        }
    }
}
