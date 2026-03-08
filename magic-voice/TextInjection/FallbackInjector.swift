//
//  FallbackInjector.swift
//  magic-voice
//
//  Magic Voice — composite injector: try AX first, fall back to clipboard paste.
//

import Foundation

/// Owns the injection policy: attempt the primary adapter; if it fails, run the
/// fallback adapter and record why the primary was skipped.
///
/// The result always describes which adapter ultimately ran and whether it
/// succeeded, giving callers and debug UIs a full picture without requiring them
/// to re-probe internal state.
@MainActor
final class FallbackInjector: TextInjecting {

    private let primary: any TextInjecting
    private let fallback: any TextInjecting

    /// - Parameters:
    ///   - primary: The preferred adapter (default: `AccessibilityInjector`).
    ///   - fallback: The backup adapter (default: `ClipboardPasteInjector`).
    init(primary: any TextInjecting, fallback: any TextInjecting) {
        self.primary = primary
        self.fallback = fallback
    }

    @discardableResult
    func inject(_ text: String) -> InjectionResult {
        guard !text.isEmpty else {
            return .failure(reason: "Empty text", text: text)
        }

        // Try primary adapter.
        let primaryResult = primary.inject(text)
        if primaryResult.succeeded {
            return primaryResult
        }

        // Primary failed — run fallback, preserving the skip reason.
        let skipReason = primaryResult.skipReason ?? "Primary adapter failed"
        let fallbackResult = fallback.inject(text)

        return InjectionResult(
            adapter: fallbackResult.adapter,
            succeeded: fallbackResult.succeeded,
            skipReason: skipReason,
            injectedText: text
        )
    }
}
