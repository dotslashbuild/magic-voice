//
//  ApplicationTerminationControllerTests.swift
//  magic-voiceTests
//

import AppKit
import Testing
@testable import Magic_Voice

@MainActor
@Suite("Application termination controller")
struct ApplicationTerminationControllerTests {
    @Test("Repeated termination requests run shutdown and reply exactly once")
    func repeatedRequestsAreCoalesced() async {
        let controller = ApplicationTerminationController()
        let latch = ApplicationTerminationTestLatch()
        let recorder = ApplicationTerminationRecorder()
        controller.install {
            await recorder.recordShutdown()
            await latch.wait()
        }

        let firstReply = controller.shouldTerminate { accepted in
            Task { await recorder.recordReply(accepted) }
        }
        let repeatedReply = controller.shouldTerminate { accepted in
            Task { await recorder.recordReply(accepted) }
        }

        #expect(firstReply == .terminateLater)
        #expect(repeatedReply == .terminateLater)
        while await recorder.shutdownCount == 0 {
            await Task.yield()
        }
        #expect(await recorder.shutdownCount == 1)
        #expect(await recorder.replies.isEmpty)

        await latch.release()
        while await recorder.replies.isEmpty {
            await Task.yield()
        }
        #expect(await recorder.replies == [true])
    }

    @Test("No installed shutdown handler terminates immediately")
    func noHandlerTerminatesImmediately() {
        let controller = ApplicationTerminationController()
        #expect(controller.shouldTerminate { _ in } == .terminateNow)
    }
}

private actor ApplicationTerminationTestLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ApplicationTerminationRecorder {
    private(set) var shutdownCount = 0
    private(set) var replies: [Bool] = []

    func recordShutdown() {
        shutdownCount += 1
    }

    func recordReply(_ accepted: Bool) {
        replies.append(accepted)
    }
}
