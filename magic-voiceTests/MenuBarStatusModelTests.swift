//
//  MenuBarStatusModelTests.swift
//  magic-voiceTests
//

import Foundation
import Testing
@testable import Magic_Voice

struct MenuBarStatusModelTests {

    @Test
    func allHealthyAndMonitoringIsReady() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            engineState: .ready,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.statusWord == "Ready")
        #expect(status.glyph == .idle)
        #expect(status.banner == nil)
    }

    @Test
    func monitoringOffIsPaused() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            engineState: .ready,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: false
        )
        #expect(status.statusWord == "Paused")
        #expect(status.glyph == .paused)
        #expect(status.banner == nil)
    }

    @Test
    func activeNotchIsRecordingEvenWithBanner() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [.accessibility],
            engineState: .ready,
            engineErrorReason: nil,
            notchActive: true,
            monitoringEnabled: true
        )
        #expect(status.statusWord == "Recording")
        #expect(status.glyph == .recording)
        #expect(status.banner == .permissions(missing: [.accessibility]))
    }

    @Test
    func missingPermissionsProduceErrorAndPermissionBanner() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [.microphone, .accessibility],
            engineState: .ready,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.statusWord == "Error")
        #expect(status.banner == .permissions(missing: [.microphone, .accessibility]))
    }

    @Test
    func unavailableEngineProducesEngineBannerWithReason() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            engineState: .unavailable,
            engineErrorReason: "Install uv: brew install uv",
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.statusWord == "Error")
        #expect(status.banner == .engine(message: "Install uv: brew install uv"))
    }

    @Test
    func unavailableEngineWithoutReasonUsesFallbackMessage() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            engineState: .unavailable,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.banner == .engine(message: "Transcription engine unavailable"))
    }

    @Test
    func permissionsBannerWinsOverEngineBanner() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [.accessibility],
            engineState: .unavailable,
            engineErrorReason: "boom",
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.banner == .permissions(missing: [.accessibility]))
    }

    @Test
    func nonTerminalEngineStatesShowNoBannerWhenSetupIsComplete() {
        for state in [TranscriptionEngineState.idle, .starting, .transcribing] {
            let status = MenuBarStatusModel.derive(
                missingPermissions: [],
                engineState: state,
                engineErrorReason: nil,
                notchActive: false,
                monitoringEnabled: true
            )
            #expect(status.banner == nil)
        }
    }

    @Test
    func setupRequiredShowsSettingUpBannerAndStatus() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            setupRequired: true,
            engineState: .idle,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.statusWord == "Setting Up")
        #expect(status.banner == .setup(message: "Setting up local speech model"))
    }

    @Test
    func loadingModelShowsPausedStateWithSetupBanner() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            setupRequired: false,
            engineState: .loadingModel,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.statusWord == "Paused")
        #expect(status.glyph == .paused)
        #expect(status.banner == .setup(message: "Setting up local speech model"))
    }

    @Test
    func setupFailureStillShowsRetryableEngineBanner() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            setupRequired: true,
            engineState: .unavailable,
            engineErrorReason: "download failed",
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.statusWord == "Error")
        #expect(status.banner == .engine(message: "download failed"))
    }
}
