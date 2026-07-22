//
//  ApplicationTerminationController.swift
//  magic-voice
//
//  Exactly-once AppKit termination deferral while the sidecar performs its
//  cooperative, bounded shutdown.
//

import AppKit

@MainActor
final class ApplicationTerminationController {
    private var handler: (() async -> Void)?
    private var terminationTask: Task<Void, Never>?

    func install(_ handler: @escaping () async -> Void) {
        self.handler = handler
    }

    func shouldTerminate(
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard let handler else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { @MainActor [weak self] in
            await handler()
            self?.handler = nil
            reply(true)
        }
        return .terminateLater
    }
}
