//
//  SidecarSmokeHarnessTests.swift
//  magic-voiceTests
//

import Foundation
import Testing
@testable import Magic_Voice

@MainActor
struct SidecarSmokeHarnessTests {
    private let scriptURL = URL(fileURLWithPath: "/fixtures/sidecar.py")

    @Test
    func passReportsSuccessAfterPongFinalAndCleanTeardown() async {
        let process = FakeSmokeProcess(
            messages: [
                SidecarJSONLinesMessage(type: "pong"),
                SidecarJSONLinesMessage(["type": "started", "request_id": "request"]),
                SidecarJSONLinesMessage([
                    "type": "chunk", "request_id": "request",
                    "text": "", "transcript": ""
                ]),
                SidecarJSONLinesMessage(["type": "done", "request_id": "request", "text": ""])
            ],
            exitBehavior: .graceful
        )
        let sink = FakeSmokeExitSink()
        let result = await makeHarness(process: process, sink: sink).run()

        #expect(result.passed)
        #expect(result.exitCode == 0)
        #expect(sink.results == [result])
        #expect(await process.actions == [.sendGracefulShutdown, .markTerminated])
        #expect(await process.isChildRunning() == false)

        let sent = await process.sentMessages
        #expect(sent.map(\.type) == ["ping", "start_stream", "audio_chunk", "finish_stream"])
        let audio = sent[2].fields["data"].flatMap { Data(base64Encoded: $0) }
        #expect(audio?.count == 1_600 * MemoryLayout<Float>.size)
        #expect(audio?.allSatisfy { $0 == 0 } == true)
    }

    @Test
    func sidecarModeStopsAfterReadinessWithoutStartingAStream() async {
        let process = FakeSmokeProcess(
            messages: [SidecarJSONLinesMessage(type: "pong")],
            exitBehavior: .graceful
        )
        let sink = FakeSmokeExitSink()

        let result = await makeHarness(
            process: process,
            sink: sink,
            launchMode: .sidecar
        ).run()

        #expect(result.passed)
        #expect(result.reason == "runtime launch and readiness verified")
        #expect(await process.sentMessages.map(\.type) == ["ping"])
        #expect(await process.actions == [.sendGracefulShutdown, .markTerminated])
    }

    @Test
    func noPongReportsUnavailableAndStillTearsDown() async {
        let process = FakeSmokeProcess(messages: [], exitBehavior: .graceful)
        let sink = FakeSmokeExitSink()
        let harness = makeHarness(
            process: process,
            sink: sink,
            clock: ImmediateSmokeClock()
        )

        let result = await harness.run()

        #expect(!result.passed)
        #expect(result.exitCode == 1)
        #expect(result.reason.contains("sidecar unavailable"))
        #expect(await process.actions == [.sendGracefulShutdown, .markTerminated])
        #expect(await process.isChildRunning() == false)
    }

    @Test
    func terminalFailureReportsFailAndPreservesCleanTeardown() async {
        let process = FakeSmokeProcess(
            messages: [
                SidecarJSONLinesMessage(type: "pong"),
                SidecarJSONLinesMessage(["type": "started", "request_id": "request"]),
                SidecarJSONLinesMessage([
                    "type": "error", "request_id": "request", "message": "model rejected silence"
                ])
            ],
            exitBehavior: .graceful
        )
        let result = await makeHarness(process: process, sink: FakeSmokeExitSink()).run()

        #expect(!result.passed)
        #expect(result.reason == "sidecar emitted terminal failure: model rejected silence")
        #expect(await process.actions == [.sendGracefulShutdown, .markTerminated])
    }

    @Test
    func teardownEscalationToSIGKILLReportsFail() async {
        let process = FakeSmokeProcess(
            messages: successfulMessages,
            exitBehavior: .sigkill
        )
        let result = await makeHarness(
            process: process,
            sink: FakeSmokeExitSink(),
            clock: SessionSuspendingLifecycleImmediateClock()
        ).run()

        #expect(!result.passed)
        #expect(result.reason == "teardown escalated to SIGKILL")
        #expect(await process.actions == [
            .sendGracefulShutdown, .sendSIGTERM, .sendSIGKILL, .markTerminated
        ])
        #expect(await process.isChildRunning() == false)
    }

    @Test
    func orphanAfterSIGKILLReportsFail() async {
        let process = FakeSmokeProcess(
            messages: successfulMessages,
            exitBehavior: .never
        )
        let result = await makeHarness(
            process: process,
            sink: FakeSmokeExitSink(),
            clock: SessionSuspendingLifecycleImmediateClock()
        ).run()

        #expect(!result.passed)
        #expect(result.reason == "orphan sidecar child remained after SIGKILL")
        #expect(await process.actions == [
            .sendGracefulShutdown, .sendSIGTERM, .sendSIGKILL, .markTerminated
        ])
        #expect(await process.isChildRunning())
    }

    @Test
    func launchArgumentParsingIsPureAndLifecycleTakesPrecedence() {
        #expect(parseSidecarSmokeLaunchMode(arguments: ["Magic Voice"]) == nil)
        #expect(parseSidecarSmokeLaunchMode(arguments: [
            "Magic Voice", "--sidecar-smoke-test"
        ]) == .sidecar)
        #expect(parseSidecarSmokeLaunchMode(arguments: [
            "Magic Voice", "--lifecycle-smoke-test"
        ]) == .lifecycle)
        #expect(parseSidecarSmokeLaunchMode(arguments: [
            "Magic Voice", "--sidecar-smoke-test", "--lifecycle-smoke-test"
        ]) == .lifecycle)
    }

    private var successfulMessages: [SidecarJSONLinesMessage] {
        [
            SidecarJSONLinesMessage(type: "pong"),
            SidecarJSONLinesMessage(["type": "started", "request_id": "request"]),
            SidecarJSONLinesMessage(["type": "done", "request_id": "request", "text": ""])
        ]
    }

    private func makeHarness(
        process: FakeSmokeProcess,
        sink: FakeSmokeExitSink,
        launchMode: SidecarSmokeLaunchMode = .lifecycle,
        clock: any SidecarReadinessClock = SuspendingSmokeClock()
    ) -> SidecarSmokeHarness {
        SidecarSmokeHarness(
            runtimeLocator: FakeSmokeRuntimeLocator(),
            process: process,
            clock: clock,
            exitSink: sink,
            launchMode: launchMode,
            scriptURL: scriptURL,
            requestID: "request",
            readinessTimeout: .seconds(5),
            sessionTimeout: .seconds(30),
            shutdownGrace: .milliseconds(1)
        )
    }
}

private struct FakeSmokeRuntimeLocator: SidecarRuntimeLocator {
    func locate(
        scriptURL: URL,
        model: STTModel,
        language: String,
        mode: SidecarLaunchMode
    ) -> SidecarRuntimeOutcome {
        .ready(SidecarLaunchPlan(
            executableURL: URL(fileURLWithPath: "/fixtures/python"),
            arguments: [scriptURL.path],
            workingDirectoryURL: scriptURL.deletingLastPathComponent()
        ))
    }
}

private actor FakeSmokeProcess: SidecarSmokeProcess {
    enum ExitBehavior {
        case graceful
        case sigkill
        case never
    }

    private var messages: [SidecarJSONLinesMessage]
    private let exitBehavior: ExitBehavior
    private var running = false
    private(set) var sentMessages: [SidecarJSONLinesMessage] = []
    private(set) var actions: [SidecarLifecyclePolicy.Action] = []

    init(messages: [SidecarJSONLinesMessage], exitBehavior: ExitBehavior) {
        self.messages = messages
        self.exitBehavior = exitBehavior
    }

    func launch(using plan: SidecarLaunchPlan) async throws {
        running = true
    }

    func send(_ message: SidecarJSONLinesMessage) async throws {
        sentMessages.append(message)
    }

    func receive() async throws -> SidecarJSONLinesMessage {
        if !messages.isEmpty { return messages.removeFirst() }
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    func perform(_ action: SidecarLifecyclePolicy.Action) async {
        actions.append(action)
        switch (exitBehavior, action) {
        case (.graceful, .sendGracefulShutdown), (.sigkill, .sendSIGKILL):
            running = false
        default:
            break
        }
    }

    func isChildRunning() async -> Bool { running }
}

@MainActor
private final class FakeSmokeExitSink: SidecarSmokeExitSinking {
    private(set) var results: [SidecarSmokeResult] = []

    func finish(with result: SidecarSmokeResult) {
        results.append(result)
    }
}

private struct SuspendingSmokeClock: SidecarReadinessClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(60))
    }
}

private struct ImmediateSmokeClock: SidecarReadinessClock {
    func sleep(for duration: Duration) async throws {}
}

private struct SessionSuspendingLifecycleImmediateClock: SidecarReadinessClock {
    func sleep(for duration: Duration) async throws {
        if duration != .milliseconds(1) {
            try await Task.sleep(for: .seconds(60))
        }
    }
}
