//
//  ProcessSupervisor.swift
//  magic-voice
//
//  Wraps runtime commands with the signed native helper that owns their entire
//  process group and tears it down if Magic Voice exits unexpectedly.
//

import Foundation

nonisolated struct SupervisedProcessLaunchPlan: Equatable, Sendable {
    static let executableName = "MagicVoiceProcessSupervisor"

    let executableURL: URL
    let arguments: [String]

    static func wrapping(
        executableURL: URL,
        arguments: [String],
        supervisorURL: URL,
        parentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> SupervisedProcessLaunchPlan {
        guard executableURL.path.hasPrefix("/") else {
            throw ProcessSupervisorError.commandPathMustBeAbsolute
        }
        guard parentPID > 1 else {
            throw ProcessSupervisorError.invalidParentPID
        }

        return SupervisedProcessLaunchPlan(
            executableURL: supervisorURL,
            arguments: [
                "--parent-pid", String(parentPID), "--", executableURL.path
            ] + arguments
        )
    }
}

nonisolated enum ProductProcessSupervisorLocator {
    static func executableURL(bundle: Bundle = .main) throws -> URL {
        guard let executableDirectory = bundle.executableURL?.deletingLastPathComponent() else {
            throw ProcessSupervisorError.helperMissing
        }
        let helperURL = executableDirectory.appendingPathComponent(
            SupervisedProcessLaunchPlan.executableName
        )
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ProcessSupervisorError.helperMissing
        }
        return helperURL
    }

    static func wrap(
        executableURL: URL,
        arguments: [String],
        bundle: Bundle = .main
    ) throws -> SupervisedProcessLaunchPlan {
        try SupervisedProcessLaunchPlan.wrapping(
            executableURL: executableURL,
            arguments: arguments,
            supervisorURL: try self.executableURL(bundle: bundle)
        )
    }
}

nonisolated enum ProcessSupervisorError: LocalizedError {
    case helperMissing
    case commandPathMustBeAbsolute
    case invalidParentPID

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "the signed process supervisor is missing from the app bundle"
        case .commandPathMustBeAbsolute:
            return "supervised commands require an absolute executable path"
        case .invalidParentPID:
            return "the Magic Voice process identifier is invalid"
        }
    }
}
