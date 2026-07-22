//
//  SidecarRuntimeLocator.swift
//  magic-voice
//
//  Magic Voice — locates a launchable Python sidecar runtime.
//

import Foundation

enum SidecarLaunchMode: Equatable {
    case serve
    case downloadModel
}

struct SidecarLaunchPlan: Equatable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let environment: [String: String]

    init(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        environment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
    }
}

enum SidecarRuntimeOutcome: Equatable {
    case ready(SidecarLaunchPlan)
    case needsInstall(message: String)
}

protocol SidecarRuntimeLocator {
    func locate(scriptURL: URL, model: STTModel, language: String, mode: SidecarLaunchMode) -> SidecarRuntimeOutcome
}

extension SidecarRuntimeLocator {
    func locate(scriptURL: URL, model: STTModel, language: String) -> SidecarRuntimeOutcome {
        locate(scriptURL: scriptURL, model: model, language: language, mode: .serve)
    }
}

struct ProductSidecarRuntimeLocator: SidecarRuntimeLocator {
    private let bundledLocator: BundledRuntimeLocator
    private let developmentLocator: DevelopmentUvLocator

    init(
        bundledLocator: BundledRuntimeLocator = BundledRuntimeLocator(),
        developmentLocator: DevelopmentUvLocator = DevelopmentUvLocator()
    ) {
        self.bundledLocator = bundledLocator
        self.developmentLocator = developmentLocator
    }

    func locate(scriptURL: URL, model: STTModel, language: String, mode: SidecarLaunchMode) -> SidecarRuntimeOutcome {
        guard bundledLocator.hasBundledDistribution else {
            return developmentLocator.locate(scriptURL: scriptURL, model: model, language: language, mode: mode)
        }
        return bundledLocator.locate(scriptURL: scriptURL, model: model, language: language, mode: mode)
    }
}

struct DevelopmentUvLocator: SidecarRuntimeLocator {
    var environmentPath: String
    var homeDirectory: String
    var isExecutable: (String) -> Bool

    init(
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environmentPath = environmentPath
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
    }

    func locate(scriptURL: URL, model: STTModel, language: String, mode: SidecarLaunchMode) -> SidecarRuntimeOutcome {
        let workingDirectoryURL = scriptURL.deletingLastPathComponent()
        let sidecarArguments = ["--model", model.hubID, "--language", language] + mode.sidecarArguments

        if let uvURL = findExecutable(named: "uv", standardCandidates: [
            homeDirectory + "/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv"
        ]) {
            return .ready(SidecarLaunchPlan(
                executableURL: uvURL,
                arguments: ["run", "--frozen", "python", scriptURL.path] + sidecarArguments,
                workingDirectoryURL: workingDirectoryURL
            ))
        }

        if let pythonURL = findExecutable(named: "python3", standardCandidates: [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3"
        ]) {
            return .ready(SidecarLaunchPlan(
                executableURL: pythonURL,
                arguments: [scriptURL.path] + sidecarArguments,
                workingDirectoryURL: workingDirectoryURL
            ))
        }

        return .needsInstall(message: "Install uv to run the transcription sidecar: brew install uv")
    }

    private func findExecutable(named name: String, standardCandidates: [String]) -> URL? {
        let pathEntries = environmentPath
            .split(separator: ":")
            .map { "\($0)/\(name)" }

        return (pathEntries + standardCandidates)
            .first(where: isExecutable)
            .map { URL(fileURLWithPath: $0) }
    }
}

struct BundledRuntimeLocator: SidecarRuntimeLocator {
    private let bundle: any RuntimeBundleResourceProviding
    private let fileSystem: any RuntimeFileSystem
    private let layout: ManagedRuntimeLayout

    init(
        bundle: any RuntimeBundleResourceProviding = MainRuntimeBundle(),
        applicationSupportDirectoryURL: URL? = nil,
        fileSystem: any RuntimeFileSystem = FileManagerRuntimeFileSystem()
    ) {
        self.bundle = bundle
        self.fileSystem = fileSystem
        self.layout = ManagedRuntimeLayout(
            applicationSupportDirectoryURL: applicationSupportDirectoryURL
                ?? ManagedRuntimeLayout.defaultApplicationSupportDirectory()
        )
    }

    var hasBundledDistribution: Bool {
        BundledRuntimeAssets.resolve(from: bundle) != nil
    }

    func locate(scriptURL: URL, model: STTModel, language: String, mode: SidecarLaunchMode) -> SidecarRuntimeOutcome {
        guard let assets = BundledRuntimeAssets.resolve(from: bundle) else {
            return .needsInstall(message: "Bundled uv and sidecar assets are missing from this build.")
        }
        guard ManagedRuntimeValidation.isValid(assets: assets, layout: layout, fileSystem: fileSystem) else {
            return .needsInstall(message: "Magic Voice is preparing its managed transcription runtime.")
        }

        let sidecarArguments = ["--model", model.hubID, "--language", language] + mode.sidecarArguments
        return .ready(SidecarLaunchPlan(
            executableURL: layout.uvURL,
            arguments: [
                "--project", layout.projectURL.path,
                "run",
                "--frozen",
                "--managed-python",
                "--python", ManagedRuntimeLayout.pythonVersion,
                "python",
                layout.sidecarScriptURL.path
            ] + sidecarArguments,
            workingDirectoryURL: layout.projectURL,
            environment: layout.environment
        ))
    }
}

extension SidecarLaunchMode {
    var sidecarArguments: [String] {
        switch self {
        case .serve:
            return []
        case .downloadModel:
            return ["--download-model"]
        }
    }
}
