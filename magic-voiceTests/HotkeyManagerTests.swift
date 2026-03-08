//
//  HotkeyManagerTests.swift
//  magic-voiceTests
//
//  Magic Voice — pure activation-key flag mapping tests.
//

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Magic_Voice

struct HotkeyManagerTests {

    @Test
    func functionKeyFlagTransitionMapsToDownAndUp() {
        let keyCode = UInt16(kVK_Function)

        #expect(HotkeyManager.transition(
            for: .function,
            eventKeyCode: keyCode,
            modifierFlags: [.function],
            wasPressed: false
        ) == ActivationKeyTransition(phase: .down))

        #expect(HotkeyManager.transition(
            for: .function,
            eventKeyCode: keyCode,
            modifierFlags: [],
            wasPressed: true
        ) == ActivationKeyTransition(phase: .up))
    }

    @Test
    func rightCommandFlagTransitionMapsToDownAndUp() {
        let keyCode = UInt16(kVK_RightCommand)

        #expect(HotkeyManager.transition(
            for: .rightCommand,
            eventKeyCode: keyCode,
            modifierFlags: [.command],
            wasPressed: false
        ) == ActivationKeyTransition(phase: .down))

        #expect(HotkeyManager.transition(
            for: .rightCommand,
            eventKeyCode: keyCode,
            modifierFlags: [],
            wasPressed: true
        ) == ActivationKeyTransition(phase: .up))
    }

    @Test
    func rightOptionFlagTransitionMapsToDownAndUp() {
        let keyCode = UInt16(kVK_RightOption)

        #expect(HotkeyManager.transition(
            for: .rightOption,
            eventKeyCode: keyCode,
            modifierFlags: [.option],
            wasPressed: false
        ) == ActivationKeyTransition(phase: .down))

        #expect(HotkeyManager.transition(
            for: .rightOption,
            eventKeyCode: keyCode,
            modifierFlags: [],
            wasPressed: true
        ) == ActivationKeyTransition(phase: .up))
    }

    @Test
    func unrelatedKeyCodeDoesNotEmitTransition() {
        #expect(HotkeyManager.transition(
            for: .rightCommand,
            eventKeyCode: UInt16(kVK_Command),
            modifierFlags: [.command],
            wasPressed: false
        ) == nil)
    }

    @Test
    func repeatedStateDoesNotEmitTransition() {
        #expect(HotkeyManager.transition(
            for: .function,
            eventKeyCode: UInt16(kVK_Function),
            modifierFlags: [.function],
            wasPressed: true
        ) == nil)
    }
}
