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
        case runtime(message: String, canRetry: Bool)
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
        runtimeProvisioningState: ManagedRuntimeProvisioningState = .ready,
        notchActive: Bool,
        monitoringEnabled: Bool
    ) -> MenuBarStatus {
        let banner: MenuBarStatus.Banner?
        if case .provisioning(let progress) = runtimeProvisioningState {
            banner = .runtime(message: progress.rawValue, canRetry: false)
        } else if case .failed(let message) = runtimeProvisioningState {
            banner = .runtime(message: message, canRetry: true)
        } else if !missingPermissions.isEmpty {
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
        } else if case .provisioning = runtimeProvisioningState {
            statusWord = "Setting Up"
        } else if engineState == .loadingModel {
            statusWord = "Paused"
        } else if case .setup = banner {
            statusWord = "Setting Up"
        } else if banner != nil {
            statusWord = "Error"
        } else if !monitoringEnabled {
            statusWord = "Paused"
        } else if engineState == .starting {
            statusWord = "Starting"
        } else {
            statusWord = "Ready"
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
