//
//  ManagedRuntimeProvisioner.swift
//  magic-voice
//
//  Magic Voice — installs and validates the bundled uv-managed sidecar runtime.
//

import Combine
import Foundation

protocol RuntimeBundleResourceProviding {
    func resourceURL(forResource name: String, withExtension extensionName: String?) -> URL?
}

struct MainRuntimeBundle: RuntimeBundleResourceProviding {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func resourceURL(forResource name: String, withExtension extensionName: String?) -> URL? {
        bundle.url(forResource: name, withExtension: extensionName)
    }
}

protocol RuntimeFileSystem {
    func fileExists(at url: URL) -> Bool
    func isExecutableFile(at url: URL) -> Bool
    func contentsEqual(at firstURL: URL, and secondURL: URL) -> Bool
    func createDirectory(at url: URL) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func makeExecutable(at url: URL) throws
    func write(_ data: Data, to url: URL) throws
}

struct FileManagerRuntimeFileSystem: RuntimeFileSystem {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isExecutableFile(at url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

    func contentsEqual(at firstURL: URL, and secondURL: URL) -> Bool {
        fileManager.contentsEqual(atPath: firstURL.path, andPath: secondURL.path)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func makeExecutable(at url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let existingPermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: existingPermissions | 0o111)],
            ofItemAtPath: url.path
        )
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

nonisolated struct RuntimeProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let environment: [String: String]
}

nonisolated struct RuntimeProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let standardError: String
}

protocol RuntimeProcessRunning: Sendable {
    nonisolated func run(_ request: RuntimeProcessRequest) async throws -> RuntimeProcessResult
}

struct FoundationRuntimeProcessRunner: RuntimeProcessRunning {
    nonisolated func run(_ request: RuntimeProcessRequest) async throws -> RuntimeProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardError = Pipe()
            let errorBuffer = RuntimeProcessOutputBuffer()
            process.executableURL = request.executableURL
            process.arguments = request.arguments
            process.currentDirectoryURL = request.workingDirectoryURL
            process.environment = ProcessInfo.processInfo.environment
                .merging(request.environment) { _, new in new }
            process.standardError = standardError
            process.standardOutput = FileHandle.nullDevice
            standardError.fileHandleForReading.readabilityHandler = { handle in
                errorBuffer.append(handle.availableData)
            }
            process.terminationHandler = { process in
                standardError.fileHandleForReading.readabilityHandler = nil
                errorBuffer.append(standardError.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: RuntimeProcessResult(
                    exitCode: process.terminationStatus,
                    standardError: errorBuffer.string
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

nonisolated final class RuntimeProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var string: String {
        lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.withLock { data.append(newData) }
    }
}

struct BundledRuntimeAssets: Equatable {
    let sidecarScriptURL: URL
    let pyprojectURL: URL
    let lockfileURL: URL
    let uvURL: URL

    static func resolve(from bundle: any RuntimeBundleResourceProviding) -> BundledRuntimeAssets? {
        guard
            let sidecarScriptURL = bundle.resourceURL(forResource: "sidecar", withExtension: "py"),
            let pyprojectURL = bundle.resourceURL(forResource: "pyproject", withExtension: "toml"),
            let lockfileURL = bundle.resourceURL(forResource: "uv", withExtension: "lock"),
            let uvURL = bundle.resourceURL(forResource: "uv", withExtension: nil)
        else {
            return nil
        }
        return BundledRuntimeAssets(
            sidecarScriptURL: sidecarScriptURL,
            pyprojectURL: pyprojectURL,
            lockfileURL: lockfileURL,
            uvURL: uvURL
        )
    }

    var copies: [(source: URL, name: String)] {
        [
            (sidecarScriptURL, "sidecar.py"),
            (pyprojectURL, "pyproject.toml"),
            (lockfileURL, "uv.lock"),
            (uvURL, "uv")
        ]
    }
}

struct ManagedRuntimeLayout {
    static let pythonVersion = "3.12"

    let applicationSupportDirectoryURL: URL

    var projectURL: URL { applicationSupportDirectoryURL.appendingPathComponent("Sidecar", isDirectory: true) }
    var uvURL: URL { projectURL.appendingPathComponent("uv") }
    var sidecarScriptURL: URL { projectURL.appendingPathComponent("sidecar.py") }
    var environmentURL: URL { projectURL.appendingPathComponent(".venv", isDirectory: true) }
    var environmentPythonURL: URL { environmentURL.appendingPathComponent("bin/python") }
    var readyMarkerURL: URL { projectURL.appendingPathComponent(".runtime-ready") }

    var environment: [String: String] {
        [
            "UV_PROJECT_ENVIRONMENT": environmentURL.path,
            "UV_PYTHON_INSTALL_DIR": applicationSupportDirectoryURL.appendingPathComponent("Python").path,
            "UV_CACHE_DIR": applicationSupportDirectoryURL.appendingPathComponent("uv-cache").path,
            "HF_HOME": applicationSupportDirectoryURL.appendingPathComponent("ModelCache/huggingface").path,
            "HF_HUB_CACHE": applicationSupportDirectoryURL.appendingPathComponent("ModelCache/huggingface/hub").path
        ]
    }

    static func defaultApplicationSupportDirectory(fileManager: FileManager = .default) -> URL {
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

enum ManagedRuntimeValidation {
    static func isValid(
        assets: BundledRuntimeAssets,
        layout: ManagedRuntimeLayout,
        fileSystem: any RuntimeFileSystem
    ) -> Bool {
        guard
            fileSystem.fileExists(at: layout.readyMarkerURL),
            fileSystem.isExecutableFile(at: layout.uvURL),
            fileSystem.isExecutableFile(at: layout.environmentPythonURL)
        else {
            return false
        }

        return assets.copies.allSatisfy { copy in
            let destinationURL = layout.projectURL.appendingPathComponent(copy.name)
            return fileSystem.fileExists(at: destinationURL)
                && fileSystem.contentsEqual(at: copy.source, and: destinationURL)
        }
    }
}

enum ManagedRuntimeProvisioningProgress: String, Equatable {
    case preparing = "Preparing transcription runtime…"
    case copyingAssets = "Installing transcription runtime…"
    case synchronizingEnvironment = "Downloading transcription dependencies…"
}

enum ManagedRuntimeProvisioningState: Equatable {
    case provisioning(ManagedRuntimeProvisioningProgress)
    case ready
    case failed(message: String)
}

enum ManagedRuntimeProvisioningResult: Equatable {
    case provisioned
    case alreadyProvisioned
    case failed(message: String)
}

@MainActor
final class ManagedRuntimeProvisioner: ObservableObject {
    @Published private(set) var state: ManagedRuntimeProvisioningState

    private let bundle: any RuntimeBundleResourceProviding
    private let fileSystem: any RuntimeFileSystem
    private let processRunner: any RuntimeProcessRunning
    private let layout: ManagedRuntimeLayout
    private let progressHandler: (ManagedRuntimeProvisioningProgress) -> Void

    init(
        bundle: (any RuntimeBundleResourceProviding)? = nil,
        applicationSupportDirectoryURL: URL? = nil,
        fileSystem: (any RuntimeFileSystem)? = nil,
        processRunner: (any RuntimeProcessRunning)? = nil,
        progressHandler: @escaping (ManagedRuntimeProvisioningProgress) -> Void = { _ in }
    ) {
        let resolvedBundle = bundle ?? MainRuntimeBundle()
        let resolvedFileSystem = fileSystem ?? FileManagerRuntimeFileSystem()
        self.bundle = resolvedBundle
        self.fileSystem = resolvedFileSystem
        self.processRunner = processRunner ?? FoundationRuntimeProcessRunner()
        self.layout = ManagedRuntimeLayout(
            applicationSupportDirectoryURL: applicationSupportDirectoryURL
                ?? ManagedRuntimeLayout.defaultApplicationSupportDirectory()
        )
        self.progressHandler = progressHandler

        if let assets = BundledRuntimeAssets.resolve(from: resolvedBundle) {
            state = ManagedRuntimeValidation.isValid(assets: assets, layout: layout, fileSystem: resolvedFileSystem)
                ? .ready
                : .provisioning(.preparing)
        } else {
            state = .ready
        }
    }

    var requiresProvisioning: Bool {
        if case .provisioning = state { return true }
        return false
    }

    @discardableResult
    func provision() async -> ManagedRuntimeProvisioningResult {
        emit(.preparing)

        guard let assets = BundledRuntimeAssets.resolve(from: bundle) else {
            return fail("Bundled uv and sidecar assets are missing from this build.")
        }

        do {
            try fileSystem.createDirectory(at: layout.projectURL)
            if ManagedRuntimeValidation.isValid(assets: assets, layout: layout, fileSystem: fileSystem) {
                state = .ready
                return .alreadyProvisioned
            }

            try removeIfPresent(layout.readyMarkerURL)
            try removeIfPresent(layout.environmentURL)

            emit(.copyingAssets)
            for copy in assets.copies {
                let destinationURL = layout.projectURL.appendingPathComponent(copy.name)
                if fileSystem.fileExists(at: destinationURL) {
                    if fileSystem.contentsEqual(at: copy.source, and: destinationURL) {
                        continue
                    }
                    try fileSystem.removeItem(at: destinationURL)
                }
                try fileSystem.copyItem(at: copy.source, to: destinationURL)
            }
            try fileSystem.makeExecutable(at: layout.uvURL)

            emit(.synchronizingEnvironment)
            let result = try await processRunner.run(RuntimeProcessRequest(
                executableURL: layout.uvURL,
                arguments: [
                    "sync",
                    "--project", layout.projectURL.path,
                    "--frozen",
                    "--managed-python",
                    "--python", ManagedRuntimeLayout.pythonVersion
                ],
                workingDirectoryURL: layout.projectURL,
                environment: layout.environment
            ))

            guard result.exitCode == 0 else {
                let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                return fail(detail.isEmpty
                    ? "Runtime setup failed (uv exited with status \(result.exitCode))."
                    : "Runtime setup failed: \(detail)")
            }
            guard fileSystem.isExecutableFile(at: layout.environmentPythonURL) else {
                return fail("Runtime setup finished without creating a usable Python environment.")
            }

            try fileSystem.write(Data("ready\n".utf8), to: layout.readyMarkerURL)
            state = .ready
            return .provisioned
        } catch {
            return fail("Runtime setup failed: \(error.localizedDescription)")
        }
    }

    private func emit(_ progress: ManagedRuntimeProvisioningProgress) {
        state = .provisioning(progress)
        progressHandler(progress)
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileSystem.fileExists(at: url) {
            try fileSystem.removeItem(at: url)
        }
    }

    private func fail(_ message: String) -> ManagedRuntimeProvisioningResult {
        state = .failed(message: message)
        return .failed(message: message)
    }
}
