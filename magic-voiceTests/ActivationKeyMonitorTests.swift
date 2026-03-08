//
//  ActivationKeyMonitorTests.swift
//  magic-voiceTests
//
//  Magic Voice — ActivationKeyMonitor owns the monitoring lifecycle: it gates
//  on accessibility permission, starts/stops the HotkeyManager, restarts on
//  activation-key changes, and forwards raw key down/up transitions outward.
//

import Foundation
import Testing
@testable import Magic_Voice

@MainActor
private final class FakeHotkeyMonitoring: HotkeyMonitoring {
    var activationKey: ActivationKey = .function
    var onActivationKeyDown: (() -> Void)?
    var onActivationKeyUp: (() -> Void)?
    private(set) var isMonitoring = false
    var startCalls = 0
    var stopCalls = 0
    /// Set to true to simulate `NSEvent.addGlobalMonitorForEvents` returning nil.
    var shouldFailToStart = false

    func start() {
        startCalls += 1
        isMonitoring = !shouldFailToStart
    }

    func stop() {
        stopCalls += 1
        isMonitoring = false
    }
}

@MainActor
private final class FakePermissionGate: ActivationPermissionGate {
    var granted: Bool
    var refreshCalls = 0

    init(granted: Bool) {
        self.granted = granted
    }

    func refresh() {
        refreshCalls += 1
    }

    func isGranted(_ kind: PermissionKind) -> Bool {
        granted
    }
}

@MainActor
private final class SpyConflictManager: FnKeyConflictManaging {
    var calls: [String] = []

    var claimCount: Int { calls.filter { $0 == "claim" }.count }
    var releaseCount: Int { calls.filter { $0 == "release" }.count }

    func claimFnKey() { calls.append("claim") }
    func releaseFnKey() { calls.append("release") }
}

@MainActor
struct ActivationKeyMonitorTests {

    private func makeMonitor(
        granted: Bool,
        activationKey: ActivationKey = .function,
        spy: SpyConflictManager? = nil
    ) -> (ActivationKeyMonitor, FakeHotkeyMonitoring, FakePermissionGate, SpyConflictManager) {
        let hotkey = FakeHotkeyMonitoring()
        let gate = FakePermissionGate(granted: granted)
        let spy = spy ?? SpyConflictManager()
        let monitor = ActivationKeyMonitor(
            hotkeyManager: hotkey,
            permissionGate: gate,
            activationKeyProvider: { activationKey },
            conflictController: spy
        )
        return (monitor, hotkey, gate, spy)
    }

    @Test
    func enableGatesOnPermissionWhenNotGranted() {
        let (monitor, hotkey, _, _) = makeMonitor(granted: false)

        monitor.enable()

        #expect(monitor.isEnabled == false)
        #expect(hotkey.startCalls == 0)
        #expect(monitor.lastEventDescription.contains("Grant Accessibility"))
    }

    @Test
    func enableStartsHotkeyManagerWhenGranted() {
        let (monitor, hotkey, _, _) = makeMonitor(granted: true)

        monitor.enable()

        #expect(monitor.isEnabled)
        #expect(hotkey.startCalls == 1)
        #expect(hotkey.isMonitoring)
        #expect(monitor.lastEventDescription == "Listening for \(ActivationKey.function.displayName)")
    }

    @Test
    func enableThenPauseTogglesTheHotkeyManager() {
        let (monitor, hotkey, _, _) = makeMonitor(granted: true)

        monitor.enable()
        #expect(monitor.isEnabled)

        monitor.pause()
        #expect(monitor.isEnabled == false)
        #expect(hotkey.stopCalls == 1)
        #expect(hotkey.isMonitoring == false)
        #expect(monitor.lastEventDescription == "Hotkey monitoring paused")
    }

    @Test
    func permissionChangeDoesNotAutoResumeAfterUserPause() {
        let (monitor, hotkey, _, _) = makeMonitor(granted: true)
        monitor.enable()
        monitor.pause()

        // Simulate a reactive permission-status re-evaluation.
        monitor.enableIfPermitted()

        #expect(monitor.isEnabled == false)
        #expect(hotkey.startCalls == 1) // not started again
    }

    @Test
    func enableIfPermittedStartsWhenNotPaused() {
        let (monitor, hotkey, _, _) = makeMonitor(granted: true)

        monitor.enableIfPermitted()

        #expect(monitor.isEnabled)
        #expect(hotkey.startCalls == 1)
    }

    @Test
    func forwardsKeyDownAndKeyUpTransitions() {
        let (monitor, hotkey, _, _) = makeMonitor(granted: true)
        var transitions: [ActivationKeyMonitor.Transition] = []
        monitor.onActivationKeyTransition = { transitions.append($0) }

        hotkey.onActivationKeyDown?()
        hotkey.onActivationKeyUp?()

        #expect(transitions == [.down, .up])
    }

    @Test
    func activationKeyChangeRestartsMonitoringWhenEnabled() {
        let (monitor, hotkey, _, _) = makeMonitor(granted: true)
        monitor.enable()
        #expect(hotkey.startCalls == 1)

        monitor.activationKeyDidChange()

        #expect(hotkey.stopCalls == 1)
        #expect(hotkey.startCalls == 2)
        #expect(hotkey.isMonitoring)
    }

    @Test
    func activationKeyChangeDoesNotStartWhenDisabled() {
        let (monitor, hotkey, _, _) = makeMonitor(granted: true)

        monitor.activationKeyDidChange()

        #expect(hotkey.startCalls == 0)
        #expect(hotkey.stopCalls == 0)
        #expect(monitor.isEnabled == false)
    }

    // MARK: - FnKeyConflictManaging claim/release tests

    @Test
    func enableWithFunctionKeyClaimsAfterStart() {
        let (monitor, _, _, spy) = makeMonitor(granted: true, activationKey: .function)

        monitor.enable()

        #expect(spy.claimCount == 1)
        #expect(spy.releaseCount == 0)
        // Verify ordering: claim happened after start (spy.calls order)
        #expect(spy.calls == ["claim"])
    }

    @Test
    func enableWithFunctionKeyGatedNeverClaims() {
        let (monitor, _, _, spy) = makeMonitor(granted: false, activationKey: .function)

        monitor.enable()

        #expect(spy.claimCount == 0)
        #expect(spy.releaseCount == 0)
    }

    @Test
    func enableWithRightCommandNeverClaims() {
        let (monitor, _, _, spy) = makeMonitor(granted: true, activationKey: .rightCommand)

        monitor.enable()

        #expect(spy.claimCount == 0)
        // release is called (idempotent no-op for nothing held, but called)
        #expect(spy.releaseCount == 1)
    }

    @Test
    func enableWithRightOptionNeverClaims() {
        let (monitor, _, _, spy) = makeMonitor(granted: true, activationKey: .rightOption)

        monitor.enable()

        #expect(spy.claimCount == 0)
        #expect(spy.releaseCount == 1)
    }

    @Test
    func pauseReleasesAfterFunctionKeyMonitoring() {
        let (monitor, _, _, spy) = makeMonitor(granted: true, activationKey: .function)

        monitor.enable()
        spy.calls.removeAll() // reset after enable's claim

        monitor.pause()

        #expect(spy.claimCount == 0)
        #expect(spy.releaseCount == 1)
    }

    @Test
    func enableIfPermittedClaimsForFunctionKey() {
        let (monitor, _, _, spy) = makeMonitor(granted: true, activationKey: .function)

        monitor.enableIfPermitted()

        #expect(spy.claimCount == 1)
        #expect(spy.releaseCount == 0)
    }

    @Test
    func enableIfPermittedWhilePausedIssuesNoConflictCalls() {
        let (monitor, _, _, spy) = makeMonitor(granted: true, activationKey: .function)

        monitor.pause()
        spy.calls.removeAll() // reset; only measure the enableIfPermitted call

        monitor.enableIfPermitted(refreshPermissions: false)

        #expect(spy.claimCount == 0)
        #expect(spy.releaseCount == 0)
    }

    @Test
    func activationKeyChangeThenFunctionClaimsWhileEnabled() {
        // We need a mutable key to simulate a change; use a box.
        var currentKey: ActivationKey = .rightCommand
        let hotkey = FakeHotkeyMonitoring()
        let gate = FakePermissionGate(granted: true)
        let spy = SpyConflictManager()
        let monitor = ActivationKeyMonitor(
            hotkeyManager: hotkey,
            permissionGate: gate,
            activationKeyProvider: { currentKey },
            conflictController: spy
        )

        monitor.enable()            // starts with .rightCommand → no claim
        spy.calls.removeAll()

        currentKey = .function
        monitor.activationKeyDidChange()  // now .function → claim

        #expect(spy.claimCount == 1)
        #expect(spy.releaseCount == 0)
    }

    @Test
    func enableDoesNotClaimWhenHotkeyMonitorFailsToStart() {
        let hotkey = FakeHotkeyMonitoring()
        hotkey.shouldFailToStart = true
        let gate = FakePermissionGate(granted: true)
        let spy = SpyConflictManager()
        let monitor = ActivationKeyMonitor(
            hotkeyManager: hotkey,
            permissionGate: gate,
            activationKeyProvider: { .function },
            conflictController: spy
        )

        monitor.enable()

        #expect(monitor.isEnabled == false)
        #expect(hotkey.isMonitoring == false)
        #expect(spy.claimCount == 0)
    }

    @Test
    func activationKeyChangeAwayFromFunctionReleasesWhileEnabled() {
        var currentKey: ActivationKey = .function
        let hotkey = FakeHotkeyMonitoring()
        let gate = FakePermissionGate(granted: true)
        let spy = SpyConflictManager()
        let monitor = ActivationKeyMonitor(
            hotkeyManager: hotkey,
            permissionGate: gate,
            activationKeyProvider: { currentKey },
            conflictController: spy
        )

        monitor.enable()            // .function → claim
        spy.calls.removeAll()

        currentKey = .rightOption
        monitor.activationKeyDidChange()  // away from .function → release

        #expect(spy.claimCount == 0)
        #expect(spy.releaseCount == 1)
    }
}
