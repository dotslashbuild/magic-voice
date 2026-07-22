//
//  SidecarLifecyclePolicyTests.swift
//  magic-voiceTests
//


import Testing
@testable import Magic_Voice

struct SidecarLifecyclePolicyTests {
    @Test
    func escalatesGracefulThenTermThenKill() {
        var policy = SidecarLifecyclePolicy()

        #expect(policy.handle(.shutdownRequested) == [.sendGracefulShutdown])
        #expect(policy.handle(.graceTimeoutElapsed) == [.sendSIGTERM])
        #expect(policy.handle(.graceTimeoutElapsed) == [.sendSIGKILL, .markTerminated])
        #expect(policy.handle(.childObservedExited).isEmpty)
    }

    @Test
    func childExitDuringGraceStopsEscalation() {
        var policy = SidecarLifecyclePolicy()

        #expect(policy.handle(.shutdownRequested) == [.sendGracefulShutdown])
        #expect(policy.handle(.childObservedExited) == [.markTerminated])
        #expect(policy.handle(.graceTimeoutElapsed).isEmpty)
    }

    @Test
    func childExitAfterTermStopsKillEscalation() {
        var policy = SidecarLifecyclePolicy()

        #expect(policy.handle(.shutdownRequested) == [.sendGracefulShutdown])
        #expect(policy.handle(.graceTimeoutElapsed) == [.sendSIGTERM])
        #expect(policy.handle(.childObservedExited) == [.markTerminated])
        #expect(policy.handle(.graceTimeoutElapsed).isEmpty)
    }

    @Test
    func alreadyExitedChildIsMarkedOnce() {
        var policy = SidecarLifecyclePolicy()

        #expect(policy.handle(.childObservedExited) == [.markTerminated])
        #expect(policy.handle(.shutdownRequested).isEmpty)
    }

    @Test
    func ignoresTimeoutAndDuplicateShutdownBeforeEscalationIsArmed() {
        var policy = SidecarLifecyclePolicy()

        #expect(policy.handle(.graceTimeoutElapsed).isEmpty)
        #expect(policy.handle(.shutdownRequested) == [.sendGracefulShutdown])
        #expect(policy.handle(.shutdownRequested).isEmpty)
    }
}
