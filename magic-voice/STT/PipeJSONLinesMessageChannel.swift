//
//  PipeJSONLinesMessageChannel.swift
//  magic-voice
//
//  Pipe-backed implementation used only while completing the readiness
//  handshake. Streaming installs its own reader after this channel is stopped.
//

import Foundation

actor PipeJSONLinesMessageChannel: SidecarJSONLinesMessageChannel {
    private let input: Pipe
    private let output: Pipe
    private var buffer = Data()
    private var queuedMessages: [SidecarJSONLinesMessage] = []
    private var waiters: [UUID: CheckedContinuation<SidecarJSONLinesMessage, any Error>] = [:]
    private var terminalError: (any Error)?

    init(input: Pipe, output: Pipe) {
        self.input = input
        self.output = output
    }

    func start() {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consume(data)
            }
        }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        failWaiters(with: CancellationError())
    }

    func send(_ message: SidecarJSONLinesMessage) async throws {
        let data = try JSONSerialization.data(withJSONObject: message.fields)
        var line = data
        line.append(10)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    func receive() async throws -> SidecarJSONLinesMessage {
        try Task.checkCancellation()
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            terminalError = SidecarChannelError.endedUnexpectedly
            failWaiters(with: SidecarChannelError.endedUnexpectedly)
            return
        }

        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            var fields = object.compactMapValues { $0 as? String }
            fields["type"] = type
            deliver(SidecarJSONLinesMessage(fields))
        }
    }

    private func deliver(_ message: SidecarJSONLinesMessage) {
        if let id = waiters.keys.first, let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: message)
        } else {
            queuedMessages.append(message)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func failWaiters(with error: any Error) {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: error)
        }
    }
}

private enum SidecarChannelError: LocalizedError {
    case endedUnexpectedly

    var errorDescription: String? {
        "Sidecar closed its JSONLines output before becoming ready"
    }
}
