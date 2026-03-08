//
//  HotkeyGestureMachine.swift
//  magic-voice
//
//  Magic Voice — pure activation-key gesture recognition.
//

import Foundation

struct HotkeyGestureMachine {
    enum Intent: Equatable {
        case none
        case beginPreroll
        case discardPreroll
        case beginPushToTalk
        case beginToggle
        case endSession
    }

    struct Output: Equatable {
        let intent: Intent
        let pendingDeadline: TimeInterval?

        static let none = Output(intent: .none, pendingDeadline: nil)
    }

    private enum ActiveMode {
        case idle
        case pushToTalk
        case toggle
    }

    static let holdThreshold: TimeInterval = 0.28
    static let doubleTapWindow: TimeInterval = 0.3

    /// Timer callbacks land within float-rounding distance of the advertised
    /// deadline; treat anything inside this slack as having reached it.
    private static let timingTolerance: TimeInterval = 0.001

    private var activeMode: ActiveMode = .idle
    private var pressStart: TimeInterval?
    private var holdResolved = false
    private var lastTapTime: TimeInterval?

    mutating func keyDown(at time: TimeInterval) -> Output {
        guard pressStart == nil else { return .none }

        pressStart = time
        holdResolved = false

        switch activeMode {
        case .idle:
            return Output(intent: .beginPreroll, pendingDeadline: time + Self.holdThreshold)
        case .toggle:
            return Output(intent: .none, pendingDeadline: time + Self.holdThreshold)
        case .pushToTalk:
            return .none
        }
    }

    mutating func keyUp(at time: TimeInterval) -> Output {
        guard let startedAt = pressStart else { return .none }
        pressStart = nil
        holdResolved = false

        let heldToDeadline = time >= startedAt + Self.holdThreshold - Self.timingTolerance

        switch activeMode {
        case .pushToTalk:
            activeMode = .idle
            lastTapTime = nil
            return Output(intent: .endSession, pendingDeadline: nil)

        case .toggle:
            if !heldToDeadline {
                activeMode = .idle
                lastTapTime = nil
                return Output(intent: .endSession, pendingDeadline: nil)
            }
            return .none

        case .idle:
            guard !heldToDeadline else {
                lastTapTime = nil
                return Output(intent: .discardPreroll, pendingDeadline: nil)
            }

            if let lastTapTime, time - lastTapTime <= Self.doubleTapWindow {
                activeMode = .toggle
                self.lastTapTime = nil
                return Output(intent: .beginToggle, pendingDeadline: nil)
            }

            lastTapTime = time
            return Output(intent: .discardPreroll, pendingDeadline: nil)
        }
    }

    mutating func tick(at time: TimeInterval) -> Output {
        guard activeMode == .idle,
              let startedAt = pressStart,
              !holdResolved,
              time >= startedAt + Self.holdThreshold - Self.timingTolerance else {
            return .none
        }

        activeMode = .pushToTalk
        holdResolved = true
        lastTapTime = nil
        return Output(intent: .beginPushToTalk, pendingDeadline: nil)
    }

    mutating func reset() -> Output {
        activeMode = .idle
        pressStart = nil
        holdResolved = false
        lastTapTime = nil
        return Output(intent: .discardPreroll, pendingDeadline: nil)
    }
}

struct PrerollAudioBuffer {
    private var chunks: [Data] = []

    var isEmpty: Bool {
        chunks.isEmpty
    }

    mutating func append(_ data: Data) {
        chunks.append(data)
    }

    mutating func flush() -> [Data] {
        defer { chunks.removeAll() }
        return chunks
    }

    mutating func discard() {
        chunks.removeAll()
    }
}
