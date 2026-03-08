//
//  HotkeyGestureMachineTests.swift
//  magic-voiceTests
//
//  Magic Voice — exhaustive coverage for activation-key gesture timing.
//

import Foundation
import Testing
@testable import Magic_Voice

struct HotkeyGestureMachineTests {

    @Test
    func singleTapBelowHoldThresholdArmsDoubleTapWithoutStartingSession() {
        var machine = HotkeyGestureMachine()

        #expect(machine.keyDown(at: 1).intent == .beginPreroll)
        #expect(machine.keyUp(at: 1.08).intent == .discardPreroll)
        #expect(machine.tick(at: 1.28).intent == .none)
    }

    @Test
    func doubleTapInsideWindowStartsToggle() {
        var machine = HotkeyGestureMachine()

        _ = machine.keyDown(at: 1)
        _ = machine.keyUp(at: 1.08)
        #expect(machine.keyDown(at: 1.2).intent == .beginPreroll)
        #expect(machine.keyUp(at: 1.26).intent == .beginToggle)
    }

    @Test
    func secondTapOutsideWindowDoesNotStartToggle() {
        var machine = HotkeyGestureMachine()

        _ = machine.keyDown(at: 1)
        _ = machine.keyUp(at: 1.08)
        _ = machine.keyDown(at: 1.5)
        #expect(machine.keyUp(at: 1.56).intent == .discardPreroll)
    }

    @Test
    func holdStartsPushToTalkAndReleaseEndsIt() {
        var machine = HotkeyGestureMachine()

        let down = machine.keyDown(at: 2)
        #expect(down.intent == .beginPreroll)
        #expect(down.pendingDeadline == 2 + HotkeyGestureMachine.holdThreshold)
        #expect(machine.tick(at: 2.28).intent == .beginPushToTalk)
        #expect(machine.keyUp(at: 2.4).intent == .endSession)
    }

    @Test
    func tapThenHoldStartsPushToTalkInsteadOfToggle() {
        var machine = HotkeyGestureMachine()

        _ = machine.keyDown(at: 1)
        _ = machine.keyUp(at: 1.08)

        let secondDown = machine.keyDown(at: 1.2)
        #expect(secondDown.intent == .beginPreroll)
        #expect(machine.tick(at: 1.48).intent == .beginPushToTalk)
        #expect(machine.keyUp(at: 1.7).intent == .endSession)
    }

    @Test
    func doubleTapAndHoldStartsPushToTalkWhenHoldDeadlineWins() {
        var machine = HotkeyGestureMachine()

        _ = machine.keyDown(at: 1)
        _ = machine.keyUp(at: 1.08)
        _ = machine.keyDown(at: 1.18)

        #expect(machine.tick(at: 1.46).intent == .beginPushToTalk)
        #expect(machine.keyUp(at: 1.62).intent == .endSession)
    }

    @Test
    func shortTapWhileToggleActiveStopsIt() {
        var machine = HotkeyGestureMachine()

        _ = machine.keyDown(at: 1)
        _ = machine.keyUp(at: 1.08)
        _ = machine.keyDown(at: 1.18)
        _ = machine.keyUp(at: 1.24)

        #expect(machine.keyDown(at: 2).intent == .none)
        #expect(machine.keyUp(at: 2.08).intent == .endSession)
    }

    @Test
    func holdWhileToggleActiveIsIgnored() {
        var machine = HotkeyGestureMachine()

        _ = machine.keyDown(at: 1)
        _ = machine.keyUp(at: 1.08)
        _ = machine.keyDown(at: 1.18)
        _ = machine.keyUp(at: 1.24)

        #expect(machine.keyDown(at: 2).intent == .none)
        #expect(machine.tick(at: 2.28).intent == .none)
        #expect(machine.keyUp(at: 2.4).intent == .none)
    }

    @Test
    func interleavedDuplicateEventsDoNotCreateExtraIntents() {
        var machine = HotkeyGestureMachine()

        #expect(machine.keyUp(at: 0.5).intent == .none)
        #expect(machine.keyDown(at: 1).intent == .beginPreroll)
        #expect(machine.keyDown(at: 1.1).intent == .none)
        #expect(machine.tick(at: 1.1).intent == .none)
        #expect(machine.tick(at: 1.28).intent == .beginPushToTalk)
        #expect(machine.tick(at: 1.3).intent == .none)
        #expect(machine.keyUp(at: 1.4).intent == .endSession)
    }

    @Test
    func prerollBufferFlushesAndDiscardsCapturedChunks() {
        var buffer = PrerollAudioBuffer()
        let first = Data([1, 2, 3])
        let second = Data([4, 5, 6])

        buffer.append(first)
        buffer.append(second)
        #expect(buffer.flush() == [first, second])
        #expect(buffer.isEmpty)

        buffer.append(first)
        buffer.discard()
        #expect(buffer.isEmpty)
    }
}
