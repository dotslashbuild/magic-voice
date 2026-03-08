//
//  DictationConflictController.swift
//  magic-voice
//
//  Magic Voice — borrows and returns the system `fn` key setting so Apple
//  Dictation stops double-firing while Magic Voice is monitoring.
//
//  Seam: FnUsageStore abstracts CFPreferences reads/writes. The production
//  adapter (CFPreferencesFnUsageStore) is wired in at the call site; a fake
//  (InMemoryFnUsageStore) backs unit tests.
//
//  Recovery: on init, if a previous run crashed while holding the key, the
//  saved-original value is restored immediately so the system is left clean.
//

import AppKit
import Foundation

// MARK: - Value constants

// AppleFnUsageType values confirmed via `defaults read com.apple.HIToolbox`:
//   nil/absent = key not present in domain (writeFnUsage(nil) removes it entirely)
//   0 = Do Nothing
//   1 = Change Input Source
//   2 = Emoji & Symbols
//   3 = Start Dictation  (the typical default)
private let kFnUsageKey = "AppleFnUsageType"
private let kFnUsageDisabled = 0
private let kHIToolboxDomain = "com.apple.HIToolbox" as CFString

// MARK: - FnUsageStore seam

/// Read/write access to the system `fn`-key usage preference.
/// The value is an `Int?` — nil means the key is not set in the domain.
@MainActor
protocol FnUsageStore: AnyObject {
    func readFnUsage() -> Int?
    func writeFnUsage(_ value: Int?)
}

// MARK: - Production adapter

/// Wraps CFPreferencesCopyValue / CFPreferencesSetValue on
/// `com.apple.HIToolbox` with `kCFPreferencesCurrentUser` / `kCFPreferencesAnyHost`.
@MainActor
final class CFPreferencesFnUsageStore: FnUsageStore {

    func readFnUsage() -> Int? {
        let raw = CFPreferencesCopyValue(
            kFnUsageKey as CFString,
            kHIToolboxDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard let raw else { return nil }
        return (raw as? NSNumber)?.intValue
    }

    func writeFnUsage(_ value: Int?) {
        let cfValue: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(
            kFnUsageKey as CFString,
            cfValue,
            kHIToolboxDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kHIToolboxDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}

// MARK: - Recovery-store key

/// UserDefaults key for the crash-recovery saved-original value.
/// Namespaced so it is clearly transient state, not user-facing identity settings.
private let kSavedOriginalKey = "DictationConflictController.savedOriginalFnUsageType"

/// Sentinel stored when the original value was nil (key absent), so we can
/// distinguish "no saved-original" from "saved-original was nil".
private let kNilSentinel = Int.min

// MARK: - Controller

/// Borrows and returns the system `fn`-key setting around a Magic Voice
/// monitoring session so Apple Dictation does not double-fire.
///
/// The controller is deliberately thin: it owns the policy (what to save,
/// when to guard, when to restore) and delegates all side effects to the
/// injected `FnUsageStore`. This keeps the decision logic fully testable.
@MainActor
final class DictationConflictController {

    private let store: any FnUsageStore
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var terminateObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - store: Abstraction over the CFPreferences domain. Defaults to the
    ///     production CFPreferences adapter.
    ///   - defaults: Recovery store for crash-safe save/restore. Defaults to
    ///     `.standard`; pass an ephemeral suite in tests.
    ///   - notificationCenter: Center used to observe willTerminate. Defaults to
    ///     `.default`; pass a custom center in tests to isolate from the real
    ///     NSApplication lifecycle. `NotificationCenter` is nonisolated so this
    ///     CAN be a plain default argument (no @MainActor isolation on the type).
    // NOTE: `store` uses optional-then-?? rather than a direct default value of
    // `CFPreferencesFnUsageStore()` because Swift's `-default-isolation=MainActor`
    // rejects a @MainActor-isolated type as a default argument in a synchronous
    // non-isolated context (the compiler sees default-argument evaluation as
    // nonisolated). The optional indirection is purely a language work-around.
    init(
        store: (any FnUsageStore)? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store ?? CFPreferencesFnUsageStore()
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        // Stale-original recovery: if a previous run crashed while holding the
        // key, restore it now before any new claim can happen.
        recoverIfNeeded()

        // Terminate hook: release the fn key on normal app quit so the system
        // preference is always restored. Mirrors PermissionController's pattern.
        terminateObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseFnKey()
            }
        }
    }

    deinit {
        if let terminateObserver {
            notificationCenter.removeObserver(terminateObserver)
        }
    }

    // MARK: - Public API

    /// Save the current `fn` usage value, persist it for crash recovery, and
    /// write the "disabled" value (0 = Do Nothing) so Dictation stops firing.
    ///
    /// Idempotency: if a saved-original already exists (from this run or from
    /// stale-recovery), the current value is NOT re-read — that would clobber
    /// the true original with our own `0`. We always write the disabled value.
    func claimFnKey() {
        if !hasSavedOriginal {
            // First claim: snapshot the true original.
            let current = store.readFnUsage()
            persistOriginal(current)
        }
        store.writeFnUsage(kFnUsageDisabled)
    }

    /// Restore the saved-original value and clear the crash-recovery marker.
    /// Safe to call twice — no saved-original means no-op.
    func releaseFnKey() {
        guard hasSavedOriginal else { return }
        let original = loadOriginal()
        store.writeFnUsage(original)   // nil → removes the key from the domain
        clearSavedOriginal()
    }

    // MARK: - Private helpers

    private var hasSavedOriginal: Bool {
        defaults.object(forKey: kSavedOriginalKey) != nil
    }

    /// Persist `value` in the recovery UserDefaults.
    /// nil originals are stored as the sentinel so we can distinguish
    /// "not-yet-saved" (key absent) from "original was absent from domain".
    private func persistOriginal(_ value: Int?) {
        defaults.set(value ?? kNilSentinel, forKey: kSavedOriginalKey)
    }

    /// Load the saved-original, reversing the nil-sentinel encoding.
    private func loadOriginal() -> Int? {
        let raw = defaults.integer(forKey: kSavedOriginalKey)
        return raw == kNilSentinel ? nil : raw
    }

    private func clearSavedOriginal() {
        defaults.removeObject(forKey: kSavedOriginalKey)
    }

    /// Called once in init. If the recovery store holds a saved-original from a
    /// previous run, restore the OS setting and clear the marker.
    private func recoverIfNeeded() {
        guard hasSavedOriginal else { return }
        let original = loadOriginal()
        store.writeFnUsage(original)
        clearSavedOriginal()
    }
}
