//
//  SidecarReadinessProbe.swift
//  magic-voice
//
//  Readiness handshake over the sidecar's JSONLines protocol. The channel and
//  clock are abstract so no process, pipe, or wall-clock wait is needed in tests.
//

import Foundation

nonisolated struct SidecarJSONLinesMessage: Equatable, Sendable {
    let fields: [String: String]

    init(_ fields: [String: String]) {
        self.fields = fields
    }

    init(type: String) {
        self.fields = ["type": type]
    }

    var type: String? { fields["type"] }

    static func cancelStream(requestID: String) -> Self {
        Self(["type": "cancel_stream", "request_id": requestID])
    }
}

nonisolated protocol SidecarJSONLinesMessageChannel: Sendable {
    func send(_ message: SidecarJSONLinesMessage) async throws
    func receive() async throws -> SidecarJSONLinesMessage
}

nonisolated protocol SidecarReadinessClock: Sendable {
    func sleep(for duration: Duration) async throws
}

nonisolated struct ContinuousSidecarReadinessClock: SidecarReadinessClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

nonisolated struct SidecarReadinessProbe: Sendable {
    enum Verdict: Equatable {
        case available
        case unavailable(reason: String)
    }

    private enum RaceResult: Sendable {
        case pong
        case timeout
    }

    let channel: any SidecarJSONLinesMessageChannel
    let clock: any SidecarReadinessClock
    let timeout: Duration

    init(
        channel: any SidecarJSONLinesMessageChannel,
        clock: any SidecarReadinessClock,
        timeout: Duration = .seconds(5)
    ) {
        self.channel = channel
        self.clock = clock
        self.timeout = timeout
    }

    func check() async -> Verdict {
        do {
            try await channel.send(SidecarJSONLinesMessage(type: "ping"))
            return try await withThrowingTaskGroup(of: RaceResult.self) { group in
                group.addTask {
                    while try await channel.receive().type != "pong" {
                        try Task.checkCancellation()
                    }
                    return .pong
                }
                group.addTask {
                    try await clock.sleep(for: timeout)
                    return .timeout
                }

                guard let first = try await group.next() else {
                    return .unavailable(reason: "Sidecar readiness check ended unexpectedly")
                }
                group.cancelAll()
                switch first {
                case .pong:
                    return .available
                case .timeout:
                    return .unavailable(reason: "Sidecar did not answer ping within the readiness timeout")
                }
            }
        } catch is CancellationError {
            return .unavailable(reason: "Sidecar readiness check was cancelled")
        } catch {
            return .unavailable(reason: "Sidecar readiness check failed: \(error.localizedDescription)")
        }
    }
}
