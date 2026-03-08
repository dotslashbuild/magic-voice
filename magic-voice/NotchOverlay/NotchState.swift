//
//  NotchState.swift
//  magic-voice
//
//  Magic Voice — recording overlay state.
//

import Foundation

enum NotchState: String, CaseIterable, Identifiable {
    case collapsed
    case active
    case liveText
    case finished

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .collapsed: return "Collapsed"
        case .active:    return "Active"
        case .liveText:  return "Live Text"
        case .finished:  return "Finished"
        }
    }
}
