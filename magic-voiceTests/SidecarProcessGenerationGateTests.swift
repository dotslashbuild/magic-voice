//
//  SidecarProcessGenerationGateTests.swift
//  magic-voiceTests
//

import Testing
@testable import Magic_Voice

@MainActor
@Suite("Sidecar process generation gate")
struct SidecarProcessGenerationGateTests {
    @Test("Generation B waits until teardown A finishes")
    func replacementWaitsForOldTeardown() async {
        let gate = SidecarProcessGenerationGate()
        let latch = ProcessGenerationTestLatch()
        let events = ProcessGenerationEventRecorder()

        let generationA = await gate.beginLaunch()
        gate.scheduleTeardown {
            await events.append("teardown-A-started")
            await latch.wait()
            await events.append("teardown-A-finished")
        }
        gate.invalidateCurrentGeneration()

        let replacement = Task { @MainActor in
            let generationB = await gate.beginLaunch()
            await events.append("launch-B")
            return generationB
        }

        while !(await events.values).contains("teardown-A-started") {
            await Task.yield()
        }
        #expect(!(await events.values).contains("launch-B"))
        #expect(!gate.isCurrent(generationA))

        await latch.release()
        let generationB = await replacement.value

        #expect(gate.isCurrent(generationB))
        #expect(await events.values == [
            "teardown-A-started",
            "teardown-A-finished",
            "launch-B"
        ])
    }
}

private actor ProcessGenerationTestLatch {
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

private actor ProcessGenerationEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
