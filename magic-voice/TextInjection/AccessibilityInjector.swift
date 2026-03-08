//
//  AccessibilityInjector.swift
//  magic-voice
//
//  Magic Voice — text injection via the macOS Accessibility API.
//

import AppKit
import ApplicationServices
import Foundation

/// Injects text by writing to the `kAXSelectedTextAttribute` of the focused
/// `AXUIElement`. Succeeds only when the element exists, is of a supported role
/// (or otherwise exposes settable selected text), and the write call returns
/// `kAXErrorSuccess`.
@MainActor
final class AccessibilityInjector: TextInjecting {

    @discardableResult
    func inject(_ text: String) -> InjectionResult {
        guard !text.isEmpty else {
            return .failure(reason: "Empty text", text: text)
        }

        guard let axElement = focusedWritableElement() else {
            return .failure(reason: "No writable AX element in focus", text: text)
        }

        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if setResult == .success {
            return .success(adapter: .accessibility, text: text)
        } else {
            return .failure(
                reason: "AXUIElementSetAttributeValue error \(setResult.rawValue)",
                text: text
            )
        }
    }

    // MARK: - Private helpers

    private func focusedWritableElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = focusedRef as! AXUIElement
        guard isSupportedTextElement(element) else { return nil }

        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else { return nil }

        return element
    }

    private func isSupportedTextElement(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else { return false }
        if Self.supportedRoles.contains(role) { return true }

        // Many web/editor surfaces expose a focused AXGroup/AXScrollArea that
        // still supports kAXSelectedTextAttribute — probe it directly.
        var selectedText: CFTypeRef?
        let probeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )
        return probeResult == .success
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return value as? String
    }

    private static let supportedRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        kAXScrollAreaRole
    ]
}
