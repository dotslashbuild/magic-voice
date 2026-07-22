//
//  SidecarLifecyclePolicy.swift
//  magic-voice
//
//  Pure shutdown escalation policy for the Python sidecar. Timing and process
//  operations belong to the adapter that applies the returned actions.
//

import Foundation

nonisolated struct SidecarLifecyclePolicy: Equatable {
    enum Input: Equatable {
        case shutdownRequested
        case graceTimeoutElapsed
        case childObservedExited
    }

    enum Action: Equatable {
        case sendGracefulShutdown
        case sendSIGTERM
        case sendSIGKILL
        case markTerminated
    }

    private enum State: Equatable {
        case running
        case awaitingGracefulExit
        case awaitingSIGTERMExit
        case terminated
    }

    private var state: State = .running

    mutating func handle(_ input: Input) -> [Action] {
        switch (state, input) {
        case (.running, .shutdownRequested):
            state = .awaitingGracefulExit
            return [.sendGracefulShutdown]

        case (.awaitingGracefulExit, .graceTimeoutElapsed):
            state = .awaitingSIGTERMExit
            return [.sendSIGTERM]

        case (.awaitingSIGTERMExit, .graceTimeoutElapsed):
            state = .terminated
            return [.sendSIGKILL, .markTerminated]

        case (.running, .childObservedExited),
             (.awaitingGracefulExit, .childObservedExited),
             (.awaitingSIGTERMExit, .childObservedExited):
            state = .terminated
            return [.markTerminated]

        case (.running, .graceTimeoutElapsed),
             (.awaitingGracefulExit, .shutdownRequested),
             (.awaitingSIGTERMExit, .shutdownRequested),
             (.terminated, _):
            return []
        }
    }
}
