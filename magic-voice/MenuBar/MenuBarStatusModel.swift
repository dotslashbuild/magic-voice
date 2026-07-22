//
//  MenuBarStatusModel.swift
//  magic-voice
//
//  Magic Voice — pure derivation of header status, glyph state, and
//  health banner from permission/engine/session state. Views render
//  this output without branching logic of their own.
//

import Foundation

struct MenuBarStatus: Equatable {
    enum Glyph: Equatable {
        case idle
        case recording
        case paused
    }

    enum Banner: Equatable {
        case permissions(missing: [PermissionKind])
        case setup(message: String)
        case engine(message: String)
    }

    let statusWord: String
    let glyph: Glyph
    let banner: Banner?
}

enum MenuBarStatusModel {

    static func glyph(
        notchActive: Bool,
        monitoringEnabled: Bool,
        setupPaused: Bool = false
    ) -> MenuBarStatus.Glyph {
        if notchActive { return .recording }
        if setupPaused { return .paused }
        return monitoringEnabled ? .idle : .paused
    }

    static func derive(
        missingPermissions: [PermissionKind],
        setupRequired: Bool = false,
        engineState: TranscriptionEngineState,
        engineErrorReason: String?,
        notchActive: Bool,
        monitoringEnabled: Bool
    ) -> MenuBarStatus {
        let banner: MenuBarStatus.Banner?
        if !missingPermissions.isEmpty {
            banner = .permissions(missing: missingPermissions)
        } else if engineState == .unavailable {
            banner = .engine(message: "Speech engine needs attention")
        } else if setupRequired || engineState == .loadingModel {
            banner = .setup(message: "Setting up local speech model")
        } else {
            banner = nil
        }

        let statusWord: String
        if notchActive {
            statusWord = "Recording"
        } else if engineState == .loadingModel {
            statusWord = "Paused"
        } else if case .setup = banner {
            statusWord = "Setting Up"
        } else if banner != nil {
            statusWord = "Error"
        } else {
            statusWord = monitoringEnabled ? "Ready" : "Paused"
        }

        return MenuBarStatus(
            statusWord: statusWord,
            glyph: glyph(
                notchActive: notchActive,
                monitoringEnabled: monitoringEnabled,
                setupPaused: engineState == .loadingModel
            ),
            banner: banner
        )
    }
}
