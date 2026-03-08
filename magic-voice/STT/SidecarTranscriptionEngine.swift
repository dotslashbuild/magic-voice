//
//  SidecarTranscriptionEngine.swift
//  magic-voice
//
//  Magic Voice — the Python/Nemotron sidecar adapter for `TranscriptionEngine`.
//  This is one adapter behind the seam: it owns the subprocess lifecycle and the
//  JSONLines protocol (`start_stream` / `audio_chunk` / `finish_stream` / `done`)
//  and translates them into the backend-neutral `TranscriptionEvent` stream that
//  callers depend on.
//

import Combine
import Foundation

@MainActor
final class SidecarTranscriptionEngine: ObservableObject, TranscriptionEngine {
    // MARK: TranscriptionEngine observable state
    @Published private(set) var engineState: TranscriptionEngineState = .idle
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastErrorReason: String?

    // MARK: Sidecar-specific diagnostics
    @Published private(set) var lastStderrLine: String?
    @Published private(set) var currentModelID: String?
    @Published private(set) var currentLanguage: String?

    private var transcriptionTask: Task<Void, Never>?
    private var sidecarProcess: Process?
    private var sidecarInput: Pipe?
    private var sidecarOutput: Pipe?
    private var sidecarError: Pipe?
    private var streamingRequestID: String?
    private var streamingLineParser: StreamingLineParser?
    private var streamingOnEvent: (@MainActor (TranscriptionEvent) -> Void)?
    private let runtimeLocator: any SidecarRuntimeLocator
    private let sidecarWriteQueue = DispatchQueue(label: "com.magicvoice.sidecar.write")

    init() {
        self.runtimeLocator = ProductSidecarRuntimeLocator()
    }

    init(runtimeLocator: any SidecarRuntimeLocator) {
        self.runtimeLocator = runtimeLocator
    }

    deinit {
        transcriptionTask?.cancel()
        sidecarOutput?.fileHandleForReading.readabilityHandler = nil
        sidecarProcess?.terminate()
    }

    // MARK: – Streaming session

    func startSession(
        model: STTModel,
        language: String,
        onEvent: @escaping @MainActor (TranscriptionEvent) -> Void
    ) {
        cancelSession()
        lastTranscript = ""
        lastErrorReason = nil
        engineState = .transcribing
        streamingOnEvent = onEvent

        do {
            try ensureSidecarProcess(model: model, language: language)
            guard let sidecarInput else { throw SidecarError.notConnected }

            let requestID = UUID().uuidString
            streamingRequestID = requestID
            try writeJSONLine(["type": "start_stream", "request_id": requestID], to: sidecarInput)
            startStreamingReader(requestID: requestID)
        } catch {
            let reason = "Streaming engine unavailable: \(error.localizedDescription)"
            lastErrorReason = reason
            engineState = .unavailable
            onEvent(.failed(reason: reason))
            streamingOnEvent = nil
        }
    }

    func feedAudio(_ data: Data) {
        guard engineState == .transcribing,
              let requestID = streamingRequestID,
              let sidecarInput else {
            return
        }

        writeJSONLineAsync([
            "type": "audio_chunk",
            "request_id": requestID,
            "data": data.base64EncodedString()
        ], to: sidecarInput)
    }

    func finishSession() {
        guard let requestID = streamingRequestID,
              let sidecarInput else {
            streamingOnEvent?(.final(transcript: ""))
            clearStreamingState()
            engineState = .ready
            return
        }

        writeJSONLineAsync(["type": "finish_stream", "request_id": requestID], to: sidecarInput)
    }

    func cancelSession() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        sidecarOutput?.fileHandleForReading.readabilityHandler = nil
        streamingLineParser = nil
        streamingRequestID = nil
        streamingOnEvent = nil
        engineState = sidecarProcess?.isRunning == true ? .ready : .idle
    }

    // MARK: – Engine lifecycle

    func startEngine(model: STTModel, language: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try self.ensureSidecarProcess(model: model, language: language)
            } catch {
                self.lastErrorReason = "Engine failed to start: \(error.localizedDescription)"
                self.engineState = .unavailable
            }
        }
    }

    func restartEngine(model: STTModel, language: String) {
        stopEngine()
        startEngine(model: model, language: language)
    }

    func downloadModel(model: STTModel, language: String) {
        lastErrorReason = nil
        engineState = .loadingModel

        guard let scriptURL = findSidecarScriptURL() else {
            lastErrorReason = SidecarError.scriptMissing.localizedDescription
            engineState = .unavailable
            return
        }

        let launchPlan: SidecarLaunchPlan
        switch runtimeLocator.locate(scriptURL: scriptURL, model: model, language: language, mode: .downloadModel) {
        case .ready(let plan):
            launchPlan = plan
        case .needsInstall(let message):
            lastErrorReason = message
            engineState = .unavailable
            return
        }

        Task { [weak self] in
            do {
                try await Self.runOneShotSidecarProcess(launchPlan: launchPlan)
                await MainActor.run {
                    self?.engineState = .idle
                }
            } catch {
                await MainActor.run {
                    self?.lastErrorReason = "Model download failed: \(error.localizedDescription)"
                    self?.engineState = .unavailable
                }
            }
        }
    }

    func stopEngine() {
        sidecarInput?.fileHandleForWriting.write(Data("{\"type\":\"shutdown\"}\n".utf8))
        sidecarProcess?.terminate()
        sidecarProcess = nil
        sidecarInput = nil
        sidecarOutput = nil
        sidecarError = nil
        currentModelID = nil
        currentLanguage = nil
        engineState = .idle
    }

    // MARK: – Private

    private func startStreamingReader(requestID: String) {
        guard let sidecarOutput else {
            let reason = "Streaming engine failed: output channel is missing"
            lastErrorReason = reason
            engineState = .unavailable
            streamingOnEvent?(.failed(reason: reason))
            clearStreamingState()
            return
        }

        let parser = StreamingLineParser()
        streamingLineParser = parser
        sidecarOutput.fileHandleForReading.readabilityHandler = { [weak self, weak parser] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { @MainActor [weak self] in
                    self?.handleStreamingReadFailure(SidecarError.endedUnexpectedly)
                }
                return
            }

            let lines = parser?.append(data) ?? []
            for line in lines {
                Task { @MainActor [weak self] in
                    self?.handleStreamingLine(line, requestID: requestID)
                }
            }
        }
    }

    private func handleStreamingLine(_ line: String, requestID: String) {
        guard let event = try? JSONDecoder().decode(SidecarEvent.self, from: Data(line.utf8)) else {
            return
        }

        if let eventRequestID = event.requestID, eventRequestID != requestID {
            return
        }

        switch event.type {
        case "status":
            updateEngineState(from: event)
        case "started":
            engineState = .transcribing
            streamingOnEvent?(.ready)
        case "chunk":
            let chunk = event.text ?? ""
            let transcript = event.transcript ?? lastTranscript + chunk
            lastTranscript = transcript
            streamingOnEvent?(.partial(chunk: chunk, fullTranscript: transcript))
        case "done":
            let finalTranscript = event.text ?? lastTranscript
            lastTranscript = finalTranscript
            engineState = .ready
            streamingOnEvent?(.final(transcript: finalTranscript))
            clearStreamingState()
        case "error":
            handleStreamingReadFailure(SidecarError.message(event.message ?? "Unknown sidecar error"))
        default:
            break
        }
    }

    private func handleStreamingReadFailure(_ error: Error) {
        let reason = "Streaming engine failed: \(error.localizedDescription)"
        lastErrorReason = reason
        engineState = .unavailable
        streamingOnEvent?(.failed(reason: reason))
        clearStreamingState()
    }

    private func clearStreamingState() {
        streamingRequestID = nil
        sidecarOutput?.fileHandleForReading.readabilityHandler = nil
        streamingLineParser = nil
        streamingOnEvent = nil
    }

    private func ensureSidecarProcess(model: STTModel, language: String) throws {
        if let sidecarProcess, sidecarProcess.isRunning, currentModelID == model.hubID, currentLanguage == language {
            return
        }

        if let sidecarProcess, sidecarProcess.isRunning {
            stopEngine()
        }

        guard let scriptURL = findSidecarScriptURL() else {
            throw SidecarError.scriptMissing
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        let launchPlan: SidecarLaunchPlan
        switch runtimeLocator.locate(scriptURL: scriptURL, model: model, language: language) {
        case .ready(let plan):
            launchPlan = plan
        case .needsInstall(let message):
            throw SidecarError.runtimeNeedsInstall(message)
        }

        process.executableURL = launchPlan.executableURL
        process.arguments = launchPlan.arguments
        process.currentDirectoryURL = launchPlan.workingDirectoryURL
        process.environment = ProcessInfo.processInfo.environment
            .merging(launchPlan.environment) { _, new in new }
            .merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.lastStderrLine = line
            }
        }

        engineState = .starting
        try process.run()
        sidecarProcess = process
        sidecarInput = input
        sidecarOutput = output
        sidecarError = error
        currentModelID = model.hubID
        currentLanguage = language
        engineState = .ready
    }

    private func findSidecarScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "sidecar", withExtension: "py") {
            return bundled
        }

        #if DEBUG
        // Development builds: resolve the script from the source tree so the
        // sidecar can be edited and re-run without rebuilding the app.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sidecar/sidecar.py")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        #endif

        return nil
    }

    private static func runOneShotSidecarProcess(launchPlan: SidecarLaunchPlan) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = launchPlan.executableURL
            process.arguments = launchPlan.arguments
            process.currentDirectoryURL = launchPlan.workingDirectoryURL
            process.environment = ProcessInfo.processInfo.environment
                .merging(launchPlan.environment) { _, new in new }
                .merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = error.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SidecarError.message(message?.isEmpty == false ? message! : "sidecar exited with status \(process.terminationStatus)")
            }
        }.value
    }

    private func writeJSONLine(_ object: [String: String], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        pipe.fileHandleForWriting.write(Data(line.utf8))
    }

    private func writeJSONLineAsync(_ object: [String: String], to pipe: Pipe) {
        sidecarWriteQueue.async { [weak pipe] in
            guard let pipe else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: object)
                guard var line = String(data: data, encoding: .utf8) else { return }
                line.append("\n")
                pipe.fileHandleForWriting.write(Data(line.utf8))
            } catch {
                // The reader loop will surface sidecar process failures; dropping one
                // chunk is preferable to blocking the capture callback.
            }
        }
    }

    private func updateEngineState(from event: SidecarEvent) {
        switch event.state {
        case "booted", "ready":
            engineState = .ready
        case "loading":
            engineState = .loadingModel
        case "shutdown":
            engineState = .idle
        default:
            break
        }
    }

}

private struct SidecarEvent: Decodable {
    let type: String
    let state: String?
    let text: String?
    let transcript: String?
    let message: String?
    let requestID: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case state
        case text
        case transcript
        case message
        case requestID = "request_id"
    }
}

private final class StreamingLineParser: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var buffer = Data()

    nonisolated func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var lines: [String] = []

        while let newlineIndex = buffer.firstIndex(of: 10) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }

        return lines
    }
}

private enum SidecarError: LocalizedError {
    case scriptMissing
    case runtimeNeedsInstall(String)
    case notConnected
    case endedUnexpectedly
    case message(String)

    var errorDescription: String? {
        switch self {
        case .scriptMissing:
            return "sidecar.py not found"
        case .runtimeNeedsInstall(let message):
            return message
        case .notConnected:
            return "sidecar pipes are not connected"
        case .endedUnexpectedly:
            return "sidecar output ended unexpectedly"
        case .message(let message):
            return message
        }
    }
}
