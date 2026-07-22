//
//  SidecarSmokeHarness.swift
//  magic-voice
//
//  Headless, dependency-injected lifecycle smoke check for the packaged app.
//

import Darwin
import Foundation

nonisolated enum SidecarSmokeLaunchMode: String, Equatable, Sendable {
    case sidecar = "--sidecar-smoke-test"
    case lifecycle = "--lifecycle-smoke-test"
}

nonisolated func parseSidecarSmokeLaunchMode(arguments: [String]) -> SidecarSmokeLaunchMode? {
    if arguments.contains(SidecarSmokeLaunchMode.lifecycle.rawValue) {
        return .lifecycle
    }
    if arguments.contains(SidecarSmokeLaunchMode.sidecar.rawValue) {
        return .sidecar
    }
    return nil
}

nonisolated struct SidecarSmokeResult: Equatable, Sendable {
    let passed: Bool
    let reason: String

    var exitCode: Int32 { passed ? 0 : 1 }
    var report: String { "Sidecar smoke test \(passed ? "PASS" : "FAIL"): \(reason)" }
}

@MainActor
protocol SidecarSmokeExitSinking: AnyObject {
    func finish(with result: SidecarSmokeResult)
}

@MainActor
final class StandardSidecarSmokeExitSink: SidecarSmokeExitSinking {
    func finish(with result: SidecarSmokeResult) {
        print(result.report)
        fflush(stdout)
        Darwin.exit(result.exitCode)
    }
}

nonisolated protocol SidecarSmokeProcess: SidecarJSONLinesMessageChannel {
    func launch(using plan: SidecarLaunchPlan) async throws
    func perform(_ action: SidecarLifecyclePolicy.Action) async
    func isChildRunning() async -> Bool
}

@MainActor
final class SidecarSmokeHarness {
    private let runtimeLocator: any SidecarRuntimeLocator
    private let process: any SidecarSmokeProcess
    private let clock: any SidecarReadinessClock
    private let exitSink: any SidecarSmokeExitSinking
    private let launchMode: SidecarSmokeLaunchMode
    private let scriptURL: URL
    private let model: STTModel
    private let language: String
    private let requestID: String
    private let readinessTimeout: Duration
    private let sessionTimeout: Duration
    private let shutdownGrace: Duration
    private let supervisorTerminationGrace: Duration

    init(
        runtimeLocator: any SidecarRuntimeLocator,
        process: any SidecarSmokeProcess,
        clock: any SidecarReadinessClock,
        exitSink: any SidecarSmokeExitSinking,
        launchMode: SidecarSmokeLaunchMode = .lifecycle,
        scriptURL: URL,
        model: STTModel = .nemotronStreaming06B,
        language: String = "en",
        requestID: String = "magic-voice-smoke-test",
        readinessTimeout: Duration = .seconds(5),
        sessionTimeout: Duration = .seconds(30),
        shutdownGrace: Duration = .seconds(1),
        supervisorTerminationGrace: Duration = .seconds(4)
    ) {
        self.runtimeLocator = runtimeLocator
        self.process = process
        self.clock = clock
        self.exitSink = exitSink
        self.launchMode = launchMode
        self.scriptURL = scriptURL
        self.model = model
        self.language = language
        self.requestID = requestID
        self.readinessTimeout = readinessTimeout
        self.sessionTimeout = sessionTimeout
        self.shutdownGrace = shutdownGrace
        self.supervisorTerminationGrace = supervisorTerminationGrace
    }

    @discardableResult
    func run() async -> SidecarSmokeResult {
        let sessionResult = await runSessionCheck()
        let teardownResult = await tearDownSidecar()
        let result = combine(session: sessionResult, teardown: teardownResult)
        exitSink.finish(with: result)
        return result
    }

    private func runSessionCheck() async -> SidecarSmokeResult {
        let launchPlan: SidecarLaunchPlan
        switch runtimeLocator.locate(
            scriptURL: scriptURL,
            model: model,
            language: language,
            mode: .serve
        ) {
        case .ready(let plan):
            launchPlan = plan
        case .needsInstall(let message):
            return .failure("runtime unavailable: \(message)")
        }

        do {
            try await process.launch(using: launchPlan)
        } catch {
            return .failure("sidecar launch failed: \(error.localizedDescription)")
        }

        let readiness = await SidecarReadinessProbe(
            channel: process,
            clock: clock,
            timeout: readinessTimeout
        ).check()
        guard case .available = readiness else {
            if case .unavailable(let reason) = readiness {
                return .failure("sidecar unavailable: \(reason)")
            }
            return .failure("sidecar unavailable")
        }

        guard launchMode == .lifecycle else {
            return .success("runtime launch and readiness verified")
        }

        do {
            try await process.send(SidecarJSONLinesMessage([
                "type": "start_stream",
                "request_id": requestID
            ]))

            var contract = SidecarSmokeEventContract()
            while !contract.isReady {
                let message = try await receiveBeforeSessionTimeout()
                if let failure = contract.consume(message, requestID: requestID) {
                    return .failure(failure)
                }
                if case .failed(let reason) = contract.terminalEvent {
                    return .failure("sidecar emitted terminal failure: \(reason)")
                }
            }

            try await process.send(SidecarJSONLinesMessage([
                "type": "audio_chunk",
                "request_id": requestID,
                "data": Self.silenceBuffer.base64EncodedString()
            ]))
            try await process.send(SidecarJSONLinesMessage([
                "type": "finish_stream",
                "request_id": requestID
            ]))

            while contract.terminalEvent == nil {
                let message = try await receiveBeforeSessionTimeout()
                if let failure = contract.consume(message, requestID: requestID) {
                    return .failure(failure)
                }
            }

            if case .failed(let reason) = contract.terminalEvent {
                return .failure("sidecar emitted terminal failure: \(reason)")
            }

            // A second ping is an ordering barrier: the sidecar handles stdin
            // serially and emits stdout serially, so seeing its pong proves we
            // consumed every event queued by finish_stream. This lets the smoke
            // check enforce exactly one terminal event without an arbitrary
            // post-final sleep.
            try await process.send(SidecarJSONLinesMessage(type: "ping"))
            while true {
                let message = try await receiveBeforeSessionTimeout()
                if message.type == "pong" { break }
                if let failure = contract.consume(message, requestID: requestID) {
                    return .failure(failure)
                }
            }

            switch contract.terminalEvent {
            case .final:
                return .success("readiness, streaming contract, and clean lifecycle verified")
            case .failed(let reason):
                return .failure("sidecar emitted terminal failure: \(reason)")
            case nil:
                return .failure("sidecar emitted no terminal event")
            }
        } catch is SidecarSmokeTimeoutError {
            return .failure("streaming session timed out before one terminal event")
        } catch {
            return .failure("streaming protocol failed: \(error.localizedDescription)")
        }
    }

    private func receiveBeforeSessionTimeout() async throws -> SidecarJSONLinesMessage {
        try await withThrowingTaskGroup(of: SidecarSmokeReceiveRace.self) { group in
            group.addTask { .message(try await self.process.receive()) }
            group.addTask {
                try await self.clock.sleep(for: self.sessionTimeout)
                return .timeout
            }
            guard let first = try await group.next() else { throw SidecarSmokeTimeoutError() }
            group.cancelAll()
            switch first {
            case .message(let message): return message
            case .timeout: throw SidecarSmokeTimeoutError()
            }
        }
    }

    private func tearDownSidecar() async -> SidecarSmokeTeardownResult {
        guard await process.isChildRunning() else { return .clean }

        var policy = SidecarLifecyclePolicy()
        await perform(policy.handle(.shutdownRequested))
        if await childExitedWithinGrace() {
            await perform(policy.handle(.childObservedExited))
            return .clean
        }

        await perform(policy.handle(.graceTimeoutElapsed))
        if await childExitedWithinGrace(supervisorTerminationGrace) {
            await perform(policy.handle(.childObservedExited))
            return .clean
        }

        await perform(policy.handle(.graceTimeoutElapsed))
        try? await clock.sleep(for: shutdownGrace)
        if await process.isChildRunning() {
            return .orphaned
        }
        return .requiredSIGKILL
    }

    private func childExitedWithinGrace(_ grace: Duration? = nil) async -> Bool {
        if !(await process.isChildRunning()) { return true }
        try? await clock.sleep(for: grace ?? shutdownGrace)
        return !(await process.isChildRunning())
    }

    private func perform(_ actions: [SidecarLifecyclePolicy.Action]) async {
        for action in actions {
            await process.perform(action)
        }
    }

    private func combine(
        session: SidecarSmokeResult,
        teardown: SidecarSmokeTeardownResult
    ) -> SidecarSmokeResult {
        switch teardown {
        case .clean:
            return session
        case .requiredSIGKILL:
            return .failure("teardown escalated to SIGKILL")
        case .orphaned:
            return .failure("orphan sidecar child remained after SIGKILL")
        }
    }

    private static let silenceBuffer = Data(count: 1_600 * MemoryLayout<Float>.size)
}

private enum SidecarSmokeReceiveRace: Sendable {
    case message(SidecarJSONLinesMessage)
    case timeout
}

private struct SidecarSmokeTimeoutError: Error {}

private enum SidecarSmokeTerminalEvent {
    case final
    case failed(String)
}

private struct SidecarSmokeEventContract {
    private(set) var isReady = false
    private(set) var terminalEvent: SidecarSmokeTerminalEvent?

    mutating func consume(_ message: SidecarJSONLinesMessage, requestID: String) -> String? {
        if let messageRequestID = message.fields["request_id"], messageRequestID != requestID {
            return nil
        }

        switch message.type {
        case "status", "pong":
            return nil
        case "started":
            guard !isReady else { return "streaming contract emitted .ready more than once" }
            guard terminalEvent == nil else { return "streaming contract emitted .ready after a terminal event" }
            isReady = true
            return nil
        case "chunk":
            guard isReady else { return "streaming contract emitted .partial before .ready" }
            guard terminalEvent == nil else { return "streaming contract emitted an event after termination" }
            return nil
        case "done":
            guard isReady else { return "streaming contract emitted .final before .ready" }
            guard terminalEvent == nil else { return "streaming contract emitted more than one terminal event" }
            terminalEvent = .final
            return nil
        case "error":
            guard terminalEvent == nil else { return "streaming contract emitted more than one terminal event" }
            terminalEvent = .failed(message.fields["message"] ?? "unknown sidecar error")
            return nil
        default:
            return nil
        }
    }
}

private enum SidecarSmokeTeardownResult {
    case clean
    case requiredSIGKILL
    case orphaned
}

private extension SidecarSmokeResult {
    static func success(_ reason: String) -> Self { Self(passed: true, reason: reason) }
    static func failure(_ reason: String) -> Self { Self(passed: false, reason: reason) }
}

nonisolated final class FoundationSidecarSmokeProcess: SidecarSmokeProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errorPipe: Pipe?
    private var channel: PipeJSONLinesMessageChannel?

    func launch(using plan: SidecarLaunchPlan) async throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        let channel = PipeJSONLinesMessageChannel(input: input, output: output)

        let supervisedPlan = try ProductProcessSupervisorLocator.wrap(
            executableURL: plan.executableURL,
            arguments: plan.arguments
        )
        process.executableURL = supervisedPlan.executableURL
        process.arguments = supervisedPlan.arguments
        process.currentDirectoryURL = plan.workingDirectoryURL
        process.environment = makeSidecarProcessEnvironment(
            base: ProcessInfo.processInfo.environment,
            overrides: plan.environment
        )
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { FileHandle.standardError.write(data) }
        }

        try process.run()
        lock.withLock {
            self.process = process
            self.input = input
            self.output = output
            self.errorPipe = errorPipe
            self.channel = channel
        }
        await channel.start()
    }

    func send(_ message: SidecarJSONLinesMessage) async throws {
        guard let channel = lock.withLock({ channel }) else { throw SidecarSmokeProcessError.notLaunched }
        try await channel.send(message)
    }

    func receive() async throws -> SidecarJSONLinesMessage {
        guard let channel = lock.withLock({ channel }) else { throw SidecarSmokeProcessError.notLaunched }
        return try await channel.receive()
    }

    func perform(_ action: SidecarLifecyclePolicy.Action) async {
        let state = lock.withLock { (process, channel) }
        switch action {
        case .sendGracefulShutdown:
            try? await state.1?.send(SidecarJSONLinesMessage(type: "shutdown"))
        case .sendSIGTERM:
            if state.0?.isRunning == true { state.0?.terminate() }
        case .sendSIGKILL:
            if let process = state.0, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        case .markTerminated:
            await state.1?.stop()
            lock.withLock {
                errorPipe?.fileHandleForReading.readabilityHandler = nil
            }
        }
    }

    func isChildRunning() async -> Bool {
        lock.withLock { process?.isRunning == true }
    }
}

private enum SidecarSmokeProcessError: LocalizedError {
    case notLaunched

    var errorDescription: String? { "sidecar process has not been launched" }
}

@MainActor
func makeProductionSidecarSmokeHarness(
    launchMode: SidecarSmokeLaunchMode = .lifecycle,
    exitSink: (any SidecarSmokeExitSinking)? = nil
) -> SidecarSmokeHarness? {
    guard let scriptURL = sidecarSmokeScriptURL() else { return nil }
    return SidecarSmokeHarness(
        runtimeLocator: ProductSidecarRuntimeLocator(),
        process: FoundationSidecarSmokeProcess(),
        clock: ContinuousSidecarReadinessClock(),
        exitSink: exitSink ?? StandardSidecarSmokeExitSink(),
        launchMode: launchMode,
        scriptURL: scriptURL
    )
}

nonisolated private func sidecarSmokeScriptURL() -> URL? {
    if let bundled = Bundle.main.url(forResource: "sidecar", withExtension: "py") {
        return bundled
    }
    #if DEBUG
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("sidecar/sidecar.py")
    if FileManager.default.fileExists(atPath: sourceURL.path) { return sourceURL }
    #endif
    return nil
}
