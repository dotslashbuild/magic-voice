//
//  LoginItemController.swift
//  magic-voice
//
//  Magic Voice — keeps SettingsStore.launchAtLogin in sync with the system
//  login-item registration (SMAppService.mainApp), so SettingsStore stays
//  free of ServiceManagement.
//

import Combine
import Foundation
import ServiceManagement

/// Abstraction over SMAppService.mainApp so the sync logic can be tested
/// without touching the real login-item database.
@MainActor
protocol LoginItemService {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct MainAppLoginItemService: LoginItemService {
    var isRegistered: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LoginItemController: ObservableObject {

    private let settings: SettingsStore
    private let service: any LoginItemService
    private var cancellable: AnyCancellable?

    init(settings: SettingsStore, service: any LoginItemService) {
        self.settings = settings
        self.service = service

        // The user can flip the login item in System Settings > General >
        // Login Items, so the system registration overrides the persisted bool.
        if settings.launchAtLogin != service.isRegistered {
            settings.launchAtLogin = service.isRegistered
        }

        cancellable = settings.$launchAtLogin
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                self?.apply(enabled)
            }
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled {
                guard !service.isRegistered else { return }
                try service.register()
            } else {
                guard service.isRegistered else { return }
                try service.unregister()
            }
        } catch {
            // @Published emits on willSet, so revert asynchronously rather
            // than mutating the property while its publisher is delivering.
            let actual = service.isRegistered
            Task { @MainActor [settings] in
                settings.launchAtLogin = actual
            }
        }
    }
}
