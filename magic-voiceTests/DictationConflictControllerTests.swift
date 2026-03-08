//
//  DictationConflictControllerTests.swift
//  magic-voiceTests
//
//  Magic Voice — DictationConflictController borrows and returns the system
//  `fn`-key setting (AppleFnUsageType) so Apple Dictation stops double-firing.
//  Tests use an in-memory FnUsageStore and an ephemeral UserDefaults suite so
//  they never touch real CFPreferences or UserDefaults.standard.
//

import AppKit
import Foundation
import Testing
@testable import Magic_Voice

// MARK: - Fake

@MainActor
private final class InMemoryFnUsageStore: FnUsageStore {
    var value: Int?
    var writeCalls = 0

    init(value: Int? = 3) {
        self.value = value
    }

    func readFnUsage() -> Int? { value }

    func writeFnUsage(_ newValue: Int?) {
        writeCalls += 1
        value = newValue
    }
}

// MARK: - Helpers

@MainActor
private func makeController(
    storeValue: Int? = 3,
    suiteName: String? = nil,
    notificationCenter: NotificationCenter = .default
) -> (DictationConflictController, InMemoryFnUsageStore, UserDefaults, String) {
    let name = suiteName ?? "test-DCC-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    let fnStore = InMemoryFnUsageStore(value: storeValue)
    let controller = DictationConflictController(
        store: fnStore,
        defaults: defaults,
        notificationCenter: notificationCenter
    )
    return (controller, fnStore, defaults, name)
}

// MARK: - Tests

@MainActor
struct DictationConflictControllerTests {

    @Test
    func claimSavesOriginalAndWritesDisabledValue() {
        let (controller, fnStore, defaults, name) = makeController(storeValue: 3)
        defer { defaults.removePersistentDomain(forName: name) }

        controller.claimFnKey()

        // OS should be set to 0 (Do Nothing).
        #expect(fnStore.value == 0)
        // Recovery marker must be set to the true original (3).
        #expect(defaults.object(forKey: "DictationConflictController.savedOriginalFnUsageType") != nil)
        #expect(defaults.integer(forKey: "DictationConflictController.savedOriginalFnUsageType") == 3)
    }

    @Test
    func releaseRestoresOriginalAndClearsMarker() {
        let (controller, fnStore, defaults, name) = makeController(storeValue: 3)
        defer { defaults.removePersistentDomain(forName: name) }

        controller.claimFnKey()
        controller.releaseFnKey()

        #expect(fnStore.value == 3)
        #expect(defaults.object(forKey: "DictationConflictController.savedOriginalFnUsageType") == nil)
    }

    @Test
    func doubleClaimDoesNotClobberTrueOriginal() {
        let (controller, fnStore, defaults, name) = makeController(storeValue: 3)
        defer { defaults.removePersistentDomain(forName: name) }

        controller.claimFnKey()   // saves 3, writes 0  → writeCalls = 1
        controller.claimFnKey()   // must NOT re-read (OS is now 0!) and re-save → writeCalls = 2
        controller.releaseFnKey() // must restore to 3  → writeCalls = 3

        #expect(fnStore.value == 3, "After double-claim + release, OS must be back to the TRUE original (3), not 0")
        #expect(fnStore.writeCalls == 3, "Each claim writes the disabled value and release writes one restore — three writes total")
    }

    @Test
    func releaseWithNoSavedOriginalIsANoOp() {
        let (controller, fnStore, defaults, name) = makeController(storeValue: 3)
        defer { defaults.removePersistentDomain(forName: name) }

        let writesBefore = fnStore.writeCalls
        controller.releaseFnKey()

        #expect(fnStore.writeCalls == writesBefore, "releaseFnKey with no saved-original must not write to the store")
        #expect(fnStore.value == 3, "OS value must be unchanged")
    }

    @Test
    func initRecoversStaleSavedOriginal() {
        let name = "test-DCC-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // Pre-seed a stale saved-original (simulates a crash while holding the key).
        defaults.set(3, forKey: "DictationConflictController.savedOriginalFnUsageType")

        // The OS is currently at 0 (we were holding it).
        let fnStore = InMemoryFnUsageStore(value: 0)

        // Construction must recover: restore the original and clear the marker.
        // (sut is named to make clear that init's side-effect is what's under test.)
        let sut = DictationConflictController(store: fnStore, defaults: defaults)
        _ = sut  // silence "never used" — the init side-effect is the assertion target

        #expect(fnStore.value == 3, "init must restore the stale-saved original to the OS")
        #expect(defaults.object(forKey: "DictationConflictController.savedOriginalFnUsageType") == nil,
                "init must clear the recovery marker after restoring")
    }

    @Test
    func claimWhenOriginalIsNilRestoresNilOnRelease() {
        // Edge: AppleFnUsageType is unset in the domain (nil). On release we
        // should write nil back (removing the key), not 0 or some default.
        let (controller, fnStore, defaults, name) = makeController(storeValue: nil)
        defer { defaults.removePersistentDomain(forName: name) }

        controller.claimFnKey()
        #expect(fnStore.value == 0, "OS must be set to disabled even when original was nil")

        controller.releaseFnKey()
        #expect(fnStore.value == nil, "OS key must be removed (nil) when the original was nil/unset")
    }

    @Test
    func willTerminateNotificationReleasesKey() {
        // Post willTerminateNotification through an injected center and assert
        // releaseFnKey() runs: the OS value is restored and the marker is cleared.
        // NotificationCenter.post to block-based observers on the same center is
        // synchronous, and the observer calls MainActor.assumeIsolated synchronously,
        // so release happens before post returns — no Task.yield needed.
        let center = NotificationCenter()
        let (controller, fnStore, defaults, name) = makeController(
            storeValue: 3,
            notificationCenter: center
        )
        defer { defaults.removePersistentDomain(forName: name) }

        controller.claimFnKey()
        #expect(fnStore.value == 0, "Precondition: key must be disabled after claim")

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        #expect(fnStore.value == 3, "willTerminate must restore the original fn-key value")
        #expect(
            defaults.object(forKey: "DictationConflictController.savedOriginalFnUsageType") == nil,
            "willTerminate must clear the crash-recovery marker"
        )
    }

    @Test
    func willTerminateWhenNothingClaimedIsANoOp() {
        // releaseFnKey() is idempotent — posting willTerminate when nothing is
        // claimed must not write to the store.
        let center = NotificationCenter()
        let (controller, fnStore, defaults, name) = makeController(
            storeValue: 3,
            notificationCenter: center
        )
        defer { defaults.removePersistentDomain(forName: name) }

        let writesBefore = fnStore.writeCalls

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        #expect(fnStore.writeCalls == writesBefore, "No writes when nothing was claimed")
        #expect(fnStore.value == 3, "OS value must remain unchanged")
        _ = controller
    }

    @Test
    func initWithStaleSentinelNilOriginalRestoresNil() {
        // Edge for stale-recovery: original was nil, stored as the sentinel.
        let name = "test-DCC-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // Store the sentinel value (Int.min) to represent "original was nil".
        defaults.set(Int.min, forKey: "DictationConflictController.savedOriginalFnUsageType")

        let fnStore = InMemoryFnUsageStore(value: 0)
        // (sut is named to make clear that init's side-effect is what's under test.)
        let sut = DictationConflictController(store: fnStore, defaults: defaults)
        _ = sut  // silence "never used" — the init side-effect is the assertion target

        #expect(fnStore.value == nil, "Stale nil-sentinel recovery must write nil (remove key) to the OS")
        #expect(defaults.object(forKey: "DictationConflictController.savedOriginalFnUsageType") == nil)
    }
}
