//
//  LoginItemControllerTests.swift
//  magic-voiceTests
//
//  Magic Voice — LoginItemController keeps the launchAtLogin setting and the
//  system login-item registration in sync, in both directions.
//

import Foundation
import Testing
@testable import Magic_Voice

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var isRegistered: Bool
    var registerError: Error?
    var registerCalls = 0
    var unregisterCalls = 0

    init(isRegistered: Bool = false) {
        self.isRegistered = isRegistered
    }

    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        isRegistered = true
    }

    func unregister() throws {
        unregisterCalls += 1
        isRegistered = false
    }
}

@MainActor
struct LoginItemControllerTests {

    private func makeStore() -> (SettingsStore, () -> Void) {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        return (SettingsStore(defaults: suite), { suite.removePersistentDomain(forName: suiteName) })
    }

    @Test
    func togglingOnRegistersAndTogglingOffUnregisters() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let service = FakeLoginItemService()
        let controller = LoginItemController(settings: store, service: service)
        _ = controller

        store.launchAtLogin = true
        #expect(service.isRegistered)
        #expect(service.registerCalls == 1)

        store.launchAtLogin = false
        #expect(!service.isRegistered)
        #expect(service.unregisterCalls == 1)
    }

    @Test
    func launchReconciliationAdoptsSystemStateOverPersistedBool() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.launchAtLogin = true

        // System Settings removed the login item behind the app's back.
        let service = FakeLoginItemService(isRegistered: false)
        let controller = LoginItemController(settings: store, service: service)
        _ = controller

        #expect(store.launchAtLogin == false)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
    }

    @Test
    func launchReconciliationPicksUpExternalRegistration() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        #expect(store.launchAtLogin == false)

        let service = FakeLoginItemService(isRegistered: true)
        let controller = LoginItemController(settings: store, service: service)
        _ = controller

        #expect(store.launchAtLogin == true)
        #expect(service.registerCalls == 0)
    }

    @Test
    func failedRegistrationRevertsTheToggle() async {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let service = FakeLoginItemService()
        service.registerError = NSError(domain: "test", code: 1)
        let controller = LoginItemController(settings: store, service: service)
        _ = controller

        store.launchAtLogin = true
        // The revert is dispatched asynchronously onto the main actor.
        await Task.yield()
        #expect(store.launchAtLogin == false)
        #expect(!service.isRegistered)
    }

    @Test
    func redundantToggleValuesDoNotReRegister() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let service = FakeLoginItemService(isRegistered: true)
        store.launchAtLogin = true
        let controller = LoginItemController(settings: store, service: service)
        _ = controller

        store.launchAtLogin = true
        #expect(service.registerCalls == 0)
    }
}
