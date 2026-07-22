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
    func startingEngineWhileMonitoringShowsStarting() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            engineState: .starting,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: true
        )

        #expect(status.statusWord == "Starting")
        #expect(status.glyph == .idle)
        #expect(status.banner == nil)
    }

    @Test
    func startingEngineWhileMonitoringIsDisabledShowsPaused() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            engineState: .starting,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: false
        )

        #expect(status.statusWord == "Paused")
        #expect(status.glyph == .paused)
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
    func unavailableEngineShowsUserFacingEngineBanner() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            engineState: .unavailable,
            engineErrorReason: "Install uv: brew install uv",
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.statusWord == "Error")
        #expect(status.banner == .engine(message: "Speech engine needs attention"))
    }

    @Test
    func unavailableEngineWithoutReasonUsesSameUserFacingMessage() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [],
            engineState: .unavailable,
            engineErrorReason: nil,
            notchActive: false,
            monitoringEnabled: true
        )
        #expect(status.banner == .engine(message: "Speech engine needs attention"))
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
    func everyProvisioningPhaseWinsOverMissingPermissionsWithoutRetry() {
        let phases: [ManagedRuntimeProvisioningProgress] = [
            .preparing,
            .copyingAssets,
            .synchronizingEnvironment
        ]

        for phase in phases {
            let status = MenuBarStatusModel.derive(
                missingPermissions: [.microphone, .accessibility],
                engineState: .unavailable,
                engineErrorReason: "engine error",
                runtimeProvisioningState: .provisioning(phase),
                notchActive: false,
                monitoringEnabled: true
            )

            #expect(status.statusWord == "Setting Up")
            #expect(status.banner == .runtime(message: phase.rawValue, canRetry: false))
        }
    }

    @Test
    func failedRuntimeProvidesRetryBeforePermissionsAndEngineError() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [.microphone, .accessibility],
            engineState: .unavailable,
            engineErrorReason: "engine error",
            runtimeProvisioningState: .failed(message: "Runtime setup failed: offline"),
            notchActive: false,
            monitoringEnabled: true
        )

        #expect(status.statusWord == "Error")
        #expect(status.banner == .runtime(message: "Runtime setup failed: offline", canRetry: true))
    }

    @Test
    func readyRuntimeReturnsToPermissionGuidance() {
        let status = MenuBarStatusModel.derive(
            missingPermissions: [.microphone, .accessibility],
            engineState: .unavailable,
            engineErrorReason: "engine error",
            runtimeProvisioningState: .ready,
            notchActive: false,
            monitoringEnabled: true
        )

        #expect(status.statusWord == "Error")
        #expect(status.banner == .permissions(missing: [.microphone, .accessibility]))
    }

    @Test @MainActor
    func successfulRuntimeRetryRunsSuccessAction() async {
        var didRunSuccessAction = false

        await ManagedRuntimeRetryAction.perform(
            provision: { .provisioned },
            onSuccess: { didRunSuccessAction = true }
        )

        #expect(didRunSuccessAction)
    }

    @Test @MainActor
    func failedRuntimeRetryDoesNotRunSuccessAction() async {
        var didRunSuccessAction = false

        await ManagedRuntimeRetryAction.perform(
            provision: { .failed(message: "still offline") },
            onSuccess: { didRunSuccessAction = true }
        )

        #expect(!didRunSuccessAction)
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
        #expect(status.banner == .engine(message: "Speech engine needs attention"))
    }
}
