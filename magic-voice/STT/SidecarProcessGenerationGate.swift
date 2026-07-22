//
//  SidecarProcessGenerationGate.swift
//  magic-voice
//
//  Serializes process teardown and replacement. A launch token becomes stale as
//  soon as stop begins, and generation B cannot start until teardown A returns.
//

import Foundation

@MainActor
final class SidecarProcessGenerationGate {
    private var generation: UInt64 = 0
    private var teardownTask: Task<Void, Never>?

    func beginLaunch() async -> UInt64 {
        await waitForTeardown()
        generation &+= 1
        return generation
    }

    func invalidateCurrentGeneration() {
        generation &+= 1
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    func scheduleTeardown(_ operation: @escaping @MainActor () async -> Void) {
        let precedingTeardown = teardownTask
        teardownTask = Task { @MainActor in
            await precedingTeardown?.value
            await operation()
        }
    }

    func waitForTeardown() async {
        await teardownTask?.value
        teardownTask = nil
    }
}
