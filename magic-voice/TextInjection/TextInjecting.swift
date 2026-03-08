//
//  TextInjecting.swift
//  magic-voice
//
//  Magic Voice — seam between injection policy and injection mechanisms.
//

import Foundation

// MARK: - Protocol

/// An object that can inject a string of text into the frontmost focused field.
///
/// - Note: Conforming types are free to be synchronous or delegate async work
///   internally. The return value describes exactly what happened so that callers
///   and debug UIs can report it without additional probing.
///
/// Forward-compatibility (backlog B2 — revisable streaming injection): the
/// `InjectionResult` carries the injected text, which is sufficient for a future
/// "replace previously injected text" adapter to know what to retract.  Adding a
/// revision capability should extend `TextInjecting` with a second method rather
/// than changing this one, keeping existing conformers unaffected.
@MainActor
protocol TextInjecting {
    /// Attempt to inject `text` into the current focus target.
    ///
    /// - Parameter text: The string to insert. Must not be empty.
    /// - Returns: An `InjectionResult` describing which adapter ran, whether it
    ///   succeeded, and — when the primary adapter was skipped or failed — why.
    @discardableResult
    func inject(_ text: String) -> InjectionResult
}

// MARK: - Result

/// Describes the outcome of a single text-injection attempt.
struct InjectionResult: Sendable {
    /// Which adapter ultimately produced (or attempted) the injection.
    let adapter: InjectionAdapter
    /// Whether the adapter's operation completed without error.
    let succeeded: Bool
    /// Human-readable reason the primary adapter was skipped or failed.
    /// `nil` when the primary adapter succeeded on the first try.
    let skipReason: String?
    /// The text that was (or was attempted to be) injected.
    ///
    /// Retained so that a future "retract-and-retype" feature can reference
    /// what was previously inserted without keeping additional state elsewhere.
    let injectedText: String

    /// Convenience for a clean primary-adapter success.
    static func success(adapter: InjectionAdapter, text: String) -> InjectionResult {
        InjectionResult(adapter: adapter, succeeded: true, skipReason: nil, injectedText: text)
    }

    /// Convenience for a fallback-adapter result (primary was skipped/failed).
    static func fallback(
        adapter: InjectionAdapter,
        succeeded: Bool,
        skipReason: String,
        text: String
    ) -> InjectionResult {
        InjectionResult(adapter: adapter, succeeded: succeeded, skipReason: skipReason, injectedText: text)
    }

    /// Convenience for a wholly-failed result where no adapter could run.
    static func failure(reason: String, text: String) -> InjectionResult {
        InjectionResult(adapter: .none, succeeded: false, skipReason: reason, injectedText: text)
    }
}

// MARK: - Adapter identifier

/// Identifies which concrete injection mechanism was used.
enum InjectionAdapter: String, Sendable {
    /// No adapter ran (e.g. a precondition prevented any attempt).
    case none = "None"
    /// macOS Accessibility API (`AXUIElement` selected-text attribute).
    case accessibility = "AX"
    /// Clipboard-overwrite + simulated ⌘V keystroke.
    case clipboardPaste = "Paste"
}
