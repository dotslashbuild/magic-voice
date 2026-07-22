//
//  SidecarReadinessProbeTests.swift
//  magic-voiceTests
//


import Foundation
import Testing
@testable import Magic_Voice

struct SidecarReadinessProbeTests {
    @Test
    func pongBeforeTimeoutIsAvailable() async {
        let channel = FakeReadinessChannel(messages: [
            SidecarJSONLinesMessage(["type": "status", "state": "booted"]),
            SidecarJSONLinesMessage(type: "pong")
        ])
        let probe = SidecarReadinessProbe(
            channel: channel,
            clock: SuspendingReadinessClock(),
            timeout: .seconds(1)
        )

        #expect(await probe.check() == .available)
        #expect(await channel.sentMessages == [SidecarJSONLinesMessage(type: "ping")])
    }

    @Test
    func noPongBeforeTimeoutIsUnavailable() async {
        let channel = FakeReadinessChannel(messages: [])
        let probe = SidecarReadinessProbe(
            channel: channel,
            clock: ImmediateReadinessClock(),
            timeout: .seconds(1)
        )

        #expect(await probe.check() == .unavailable(
            reason: "Sidecar did not answer ping within the readiness timeout"
        ))
        #expect(await channel.sentMessages == [SidecarJSONLinesMessage(type: "ping")])
    }
}

private actor FakeReadinessChannel: SidecarJSONLinesMessageChannel {
    private var messages: [SidecarJSONLinesMessage]
    private(set) var sentMessages: [SidecarJSONLinesMessage] = []

    init(messages: [SidecarJSONLinesMessage]) {
        self.messages = messages
    }

    func send(_ message: SidecarJSONLinesMessage) async throws {
        sentMessages.append(message)
    }

    func receive() async throws -> SidecarJSONLinesMessage {
        if !messages.isEmpty {
            return messages.removeFirst()
        }
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

private struct SuspendingReadinessClock: SidecarReadinessClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(60))
    }
}

private struct ImmediateReadinessClock: SidecarReadinessClock {
    func sleep(for duration: Duration) async throws {}
}
