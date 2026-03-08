//
//  ActivationKeyMonitor.swift
//  magic-voice
//
//  Magic Voice — owns the activation-key *monitoring lifecycle*: the permission
//  gate, and starting/stopping the NSEvent-based HotkeyManager. It forwards raw
//  activation-key down/up transitions outward; gesture recognition and the
//  recording pipeline live in the caller (DictationSession).
//
//  Phase 3: DictationConflictController is composed here via FnKeyConflictManaging
//  so claim/release lives beside start/stop. Claim happens only for .function and
//  only after the HotkeyManager has started; release happens at every teardown path.
//

import Combine
import Foundation

// MARK: - FnKeyConflictManaging seam

/// Minimal protocol for the fn-key borrow/return operations the monitor needs.
/// DictationConflictController conforms; tests inject a spy.
@MainActor
protocol FnKeyConflictManaging: AnyObject {
    func claimFnKey()
    func releaseFnKey()
}

extension DictationConflictController: FnKeyConflictManaging {}

/// Lifecycle abstraction over the NSEvent-based HotkeyManager so the monitor's
/// gate/start/stop logic can be tested without a real event tap.
@MainActor
protocol HotkeyMonitoring: AnyObject {
    var activationKey: ActivationKey { get set }
    var onActivationKeyDown: (() -> Void)? { get set }
    var onActivationKeyUp: (() -> Void)? { get set }
    var isMonitoring: Bool { get }
    func start()
    func stop()
}

extension HotkeyManager: HotkeyMonitoring {}

/// The slice of PermissionController the monitor needs to gate on input
/// monitoring access.
@MainActor
protocol ActivationPermissionGate: AnyObject {
    func refresh()
    func isGranted(_ kind: PermissionKind) -> Bool
}

extension PermissionController: ActivationPermissionGate {
    func isGranted(_ kind: PermissionKind) -> Bool {
        status(for: kind).isGranted
    }
}

@MainActor
final class ActivationKeyMonitor: ObservableObject {

    /// Phase of a raw activation-key transition forwarded to the caller.
    enum Transition {
        case down
        case up
    }

    /// The permission this monitor gates on.
    /// Phase 5: switched from .inputMonitoring to .accessibility.
    /// NSEvent global .flagsChanged monitor is treated as Accessibility-class;
    /// if the fn key stops registering with Input Monitoring denied, this gate
    /// must revert to .inputMonitoring (see plan Phase 5 — UNVERIFIED on real hardware).
    private static let gatedPermission: PermissionKind = .accessibility

    @Published private(set) var isEnabled = false
    @Published private(set) var lastEventDescription = "Waiting for activation key"

    /// Raw activation-key transition callback. Named for the raw key down/up it
    /// surfaces (not a fully-resolved gesture intent): the gesture machine and
    /// timing driver live in the caller, so the monitor cannot produce intents.
    var onActivationKeyTransition: ((Transition) -> Void)?

    private let hotkeyManager: any HotkeyMonitoring
    private let permissionGate: any ActivationPermissionGate
    private let activationKeyProvider: () -> ActivationKey
    private let conflictController: any FnKeyConflictManaging

    private var pausedByUser = false

    // NOTE: conflictController uses optional-then-?? rather than a direct default
    // value of DictationConflictController() because Swift's -default-isolation=MainActor
    // rejects a @MainActor-isolated type as a default argument in a synchronous
    // non-isolated context. The optional indirection is purely a language work-around.
    init(
        hotkeyManager: any HotkeyMonitoring,
        permissionGate: any ActivationPermissionGate,
        activationKeyProvider: @escaping () -> ActivationKey,
        conflictController: (any FnKeyConflictManaging)? = nil
    ) {
        self.hotkeyManager = hotkeyManager
        self.permissionGate = permissionGate
        self.activationKeyProvider = activationKeyProvider
        self.conflictController = conflictController ?? DictationConflictController()

        hotkeyManager.activationKey = activationKeyProvider()
        hotkeyManager.onActivationKeyDown = { [weak self] in
            self?.onActivationKeyTransition?(.down)
        }
        hotkeyManager.onActivationKeyUp = { [weak self] in
            self?.onActivationKeyTransition?(.up)
        }
    }

    /// Start monitoring if the gate allows. Clears the user-paused flag so an
    /// explicit enable overrides a prior pause.
    func enable(refreshPermissions: Bool = true) {
        pausedByUser = false
        evaluateGate(refreshPermissions: refreshPermissions)
    }

    /// Re-evaluate the gate without clearing the user-paused flag. Used on
    /// launch and reactively when permission status changes, so a permission
    /// flip doesn't auto-resume after the user explicitly paused.
    func enableIfPermitted(refreshPermissions: Bool = false) {
        evaluateGate(refreshPermissions: refreshPermissions)
    }

    /// Stop monitoring at the user's request. The user-paused flag keeps a later
    /// permission-status change from auto-resuming.
    func pause() {
        pausedByUser = true
        permissionGate.refresh()
        hotkeyManager.stop()
        isEnabled = false
        syncConflictClaim()
        lastEventDescription = "Hotkey monitoring paused"
    }

    /// React to an activation-key change: retarget the HotkeyManager and, if
    /// currently monitoring, stop/restart it so the new key takes effect.
    func activationKeyDidChange() {
        let wasMonitoring = isEnabled
        let key = activationKeyProvider()
        hotkeyManager.activationKey = key
        if wasMonitoring {
            hotkeyManager.stop()
            hotkeyManager.start()
            lastEventDescription = "Listening for \(key.displayName)"
        }
        syncConflictClaim()
    }

    private func evaluateGate(refreshPermissions: Bool) {
        guard !pausedByUser else { return }
        guard !isEnabled else { return }

        if refreshPermissions {
            permissionGate.refresh()
        }

        guard permissionGate.isGranted(Self.gatedPermission) else {
            isEnabled = false
            lastEventDescription = "Grant Accessibility to use \(activationKeyProvider().displayName)"
            return
        }

        hotkeyManager.activationKey = activationKeyProvider()
        hotkeyManager.start()
        guard hotkeyManager.isMonitoring else {
            isEnabled = false
            lastEventDescription = "Grant Accessibility to use \(activationKeyProvider().displayName)"
            syncConflictClaim()
            return
        }
        isEnabled = true
        syncConflictClaim()
        lastEventDescription = "Listening for \(activationKeyProvider().displayName)"
    }

    /// Single decision point: claim the fn key iff we are enabled AND the
    /// current activation key is .function; release unconditionally otherwise.
    /// Safe to call at any state transition — releaseFnKey() is idempotent.
    private func syncConflictClaim() {
        if isEnabled && activationKeyProvider() == .function {
            conflictController.claimFnKey()
        } else {
            conflictController.releaseFnKey()
        }
    }
}
