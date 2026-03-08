//
//  PermissionStatus.swift
//  magic-voice
//
//  Magic Voice — normalized permission state for the menu bar UI.
//

import SwiftUI

enum PermissionStatus: Equatable {
    case granted
    case needsAccess
    case denied
    case restricted
    case unknown

    var isGranted: Bool {
        self == .granted
    }

    var title: String {
        switch self {
        case .granted: return "Granted"
        case .needsAccess: return "Needs access"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .granted: return .green
        case .needsAccess: return .orange
        case .denied, .restricted: return .red
        case .unknown: return .gray
        }
    }
}
