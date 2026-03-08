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
    private let managedLocator: ManagedUvRuntimeLocator
    private let developmentLocator: DevelopmentUvLocator

    init(
        managedLocator: ManagedUvRuntimeLocator = ManagedUvRuntimeLocator(),
        developmentLocator: DevelopmentUvLocator = DevelopmentUvLocator()
    ) {
        self.managedLocator = managedLocator
        self.developmentLocator = developmentLocator
    }

    func locate(scriptURL: URL, model: STTModel, language: String, mode: SidecarLaunchMode) -> SidecarRuntimeOutcome {
        switch managedLocator.locate(scriptURL: scriptURL, model: model, language: language, mode: mode) {
        case .ready(let plan):
            return .ready(plan)
        case .needsInstall:
            return developmentLocator.locate(scriptURL: scriptURL, model: model, language: language, mode: mode)
        }
    }
}

struct ManagedUvRuntimeLocator: SidecarRuntimeLocator {
    var bundledUvURL: URL?
    var applicationSupportDirectoryURL: URL
    var isExecutable: (String) -> Bool
    var fileManager: FileManager

    init(
        bundledUvURL: URL? = Bundle.main.url(forResource: "uv", withExtension: nil),
        applicationSupportDirectoryURL: URL? = nil,
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileManager: FileManager = .default
    ) {
        self.bundledUvURL = bundledUvURL
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
            ?? ManagedUvRuntimeLocator.defaultApplicationSupportDirectory(fileManager: fileManager)
        self.isExecutable = isExecutable
        self.fileManager = fileManager
    }

    func locate(scriptURL: URL, model: STTModel, language: String, mode: SidecarLaunchMode) -> SidecarRuntimeOutcome {
        guard let bundledUvURL, isExecutable(bundledUvURL.path) else {
            return .needsInstall(message: "Bundled uv runtime is missing from this build.")
        }

        do {
            let managedProjectURL = try prepareManagedProject(from: scriptURL)
            let supportURL = applicationSupportDirectoryURL
            let managedScriptURL = managedProjectURL.appendingPathComponent("sidecar.py")
            let sidecarArguments = ["--model", model.hubID, "--language", language] + mode.sidecarArguments

            return .ready(SidecarLaunchPlan(
                executableURL: bundledUvURL,
                arguments: [
                    "--project", managedProjectURL.path,
                    "run",
                    "--frozen",
                    "--managed-python",
                    "--python", "3.12",
                    "python",
                    managedScriptURL.path
                ] + sidecarArguments,
                workingDirectoryURL: managedProjectURL,
                environment: [
                    "UV_PROJECT_ENVIRONMENT": supportURL.appendingPathComponent("Sidecar/.venv").path,
                    "UV_PYTHON_INSTALL_DIR": supportURL.appendingPathComponent("Python").path,
                    "UV_CACHE_DIR": supportURL.appendingPathComponent("uv-cache").path,
                    "HF_HOME": supportURL.appendingPathComponent("ModelCache/huggingface").path,
                    "HF_HUB_CACHE": supportURL.appendingPathComponent("ModelCache/huggingface/hub").path
                ]
            ))
        } catch {
            return .needsInstall(message: "Failed to prepare the managed sidecar runtime: \(error.localizedDescription)")
        }
    }

    private func prepareManagedProject(from scriptURL: URL) throws -> URL {
        let projectURL = applicationSupportDirectoryURL.appendingPathComponent("Sidecar", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let sourceDirectoryURL = scriptURL.deletingLastPathComponent()
        try copyIfChanged(from: scriptURL, to: projectURL.appendingPathComponent("sidecar.py"))
        try copyIfChanged(
            from: sourceDirectoryURL.appendingPathComponent("pyproject.toml"),
            to: projectURL.appendingPathComponent("pyproject.toml")
        )
        try copyIfChanged(
            from: sourceDirectoryURL.appendingPathComponent("uv.lock"),
            to: projectURL.appendingPathComponent("uv.lock")
        )

        return projectURL
    }

    private func copyIfChanged(from sourceURL: URL, to destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard !fileManager.contentsEqual(atPath: sourceURL.path, andPath: destinationURL.path) else {
                return
            }
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func defaultApplicationSupportDirectory(fileManager: FileManager) -> URL {
        let baseURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectoryName = Bundle.main.bundleIdentifier ?? "Magic Voice"
        return (baseURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent(appDirectoryName, isDirectory: true)
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
    func locate(scriptURL: URL, model: STTModel, language: String, mode: SidecarLaunchMode) -> SidecarRuntimeOutcome {
        .needsInstall(message: "A bundled Magic Voice Python runtime is not included in this build yet.")
    }
}

private extension SidecarLaunchMode {
    var sidecarArguments: [String] {
        switch self {
        case .serve:
            return []
        case .downloadModel:
            return ["--download-model"]
        }
    }
}
