//
//  ProcessSupervisorHostDeathSmoke.swift
//  magic-voice
//
//  Lightweight built-app fixture entry point. It launches a test worker through
//  the production supervisor, then remains alive so the external smoke script
//  can SIGKILL Magic Voice and inspect every recorded PID.
//

import Foundation

nonisolated struct ProcessSupervisorHostDeathSmokeRequest: Equatable {
    static let argument = "--process-supervisor-host-death-smoke"

    let fixtureURL: URL
    let stateDirectoryURL: URL
}

nonisolated func parseProcessSupervisorHostDeathSmokeRequest(
    arguments: [String]
) -> ProcessSupervisorHostDeathSmokeRequest? {
    guard let argumentIndex = arguments.firstIndex(
        of: ProcessSupervisorHostDeathSmokeRequest.argument
    ) else {
        return nil
    }
    guard arguments.distance(from: argumentIndex, to: arguments.endIndex) >= 3 else {
        return nil
    }
    let fixtureIndex = arguments.index(after: argumentIndex)
    let stateDirectoryIndex = arguments.index(after: fixtureIndex)
    return ProcessSupervisorHostDeathSmokeRequest(
        fixtureURL: URL(fileURLWithPath: arguments[fixtureIndex]),
        stateDirectoryURL: URL(fileURLWithPath: arguments[stateDirectoryIndex])
    )
}

@MainActor
final class ProcessSupervisorHostDeathSmokeRunner {
    private var supervisorProcess: Process?

    func launch(_ request: ProcessSupervisorHostDeathSmokeRequest) throws {
        let process = Process()
        let plan = try ProductProcessSupervisorLocator.wrap(
            executableURL: request.fixtureURL,
            arguments: ["ignore-term", request.stateDirectoryURL.path]
        )
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = request.stateDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        supervisorProcess = process

        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(
            to: request.stateDirectoryURL.appendingPathComponent("app.pid"),
            options: .atomic
        )
        try Data("\(process.processIdentifier)\n".utf8).write(
            to: request.stateDirectoryURL.appendingPathComponent("supervisor.pid"),
            options: .atomic
        )
    }
}
