//
//  RuntimeTestDoubles.swift
//  magic-voiceTests
//


import Foundation
@testable import Magic_Voice

struct FakeRuntimeBundle: RuntimeBundleResourceProviding {
    let resources: [String: URL]

    func resourceURL(forResource name: String, withExtension extensionName: String?) -> URL? {
        resources[extensionName.map { "\(name).\($0)" } ?? name]
    }
}

final class FakeRuntimeFileSystem: RuntimeFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private var executables: Set<String> = []

    func addFile(_ url: URL, contents: String = "fixture") {
        lock.withLock { files[url.path] = Data(contents.utf8) }
    }

    func addExecutable(_ url: URL, contents: String = "fixture") {
        lock.withLock {
            files[url.path] = Data(contents.utf8)
            executables.insert(url.path)
        }
    }

    func fileExists(at url: URL) -> Bool {
        lock.withLock { files[url.path] != nil || directories.contains(url.path) }
    }

    func isExecutableFile(at url: URL) -> Bool {
        lock.withLock { executables.contains(url.path) }
    }

    func contentsEqual(at firstURL: URL, and secondURL: URL) -> Bool {
        lock.withLock { files[firstURL.path] != nil && files[firstURL.path] == files[secondURL.path] }
    }

    func createDirectory(at url: URL) throws {
        lock.withLock { _ = directories.insert(url.path) }
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try lock.withLock {
            guard let data = files[sourceURL.path] else { throw CocoaError(.fileNoSuchFile) }
            files[destinationURL.path] = data
            if executables.contains(sourceURL.path) {
                executables.insert(destinationURL.path)
            }
        }
    }

    func removeItem(at url: URL) throws {
        lock.withLock {
            files = files.filter { !$0.key.hasPrefix(url.path) }
            directories = directories.filter { !$0.hasPrefix(url.path) }
            executables = executables.filter { !$0.hasPrefix(url.path) }
        }
    }

    func makeExecutable(at url: URL) throws {
        try lock.withLock {
            guard files[url.path] != nil else { throw CocoaError(.fileNoSuchFile) }
            executables.insert(url.path)
        }
    }

    func write(_ data: Data, to url: URL) throws {
        lock.withLock { files[url.path] = data }
    }
}

final class FakeRuntimeProcessRunner: RuntimeProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [RuntimeProcessResult]
    private var requests: [RuntimeProcessRequest] = []
    private let onRun: @Sendable (RuntimeProcessResult) -> Void

    init(
        results: [RuntimeProcessResult],
        onRun: @escaping @Sendable (RuntimeProcessResult) -> Void = { _ in }
    ) {
        self.results = results
        self.onRun = onRun
    }

    var callCount: Int {
        lock.withLock { requests.count }
    }

    var lastRequest: RuntimeProcessRequest? {
        lock.withLock { requests.last }
    }

    nonisolated func run(_ request: RuntimeProcessRequest) async throws -> RuntimeProcessResult {
        let result = lock.withLock {
            requests.append(request)
            return results.removeFirst()
        }
        onRun(result)
        return result
    }
}

@MainActor
final class RuntimeTestHarness {
    let supportURL = URL(fileURLWithPath: "/support", isDirectory: true)
    let fileSystem = FakeRuntimeFileSystem()
    let bundle: FakeRuntimeBundle
    let assets: BundledRuntimeAssets

    init() {
        let sidecarURL = URL(fileURLWithPath: "/bundle/sidecar.py")
        let pyprojectURL = URL(fileURLWithPath: "/bundle/pyproject.toml")
        let lockfileURL = URL(fileURLWithPath: "/bundle/uv.lock")
        let uvURL = URL(fileURLWithPath: "/bundle/uv")
        bundle = FakeRuntimeBundle(resources: [
            "sidecar.py": sidecarURL,
            "pyproject.toml": pyprojectURL,
            "uv.lock": lockfileURL,
            "uv": uvURL
        ])
        assets = BundledRuntimeAssets(
            sidecarScriptURL: sidecarURL,
            pyprojectURL: pyprojectURL,
            lockfileURL: lockfileURL,
            uvURL: uvURL
        )
        fileSystem.addFile(sidecarURL, contents: "sidecar")
        fileSystem.addFile(pyprojectURL, contents: "project")
        fileSystem.addFile(lockfileURL, contents: "lock")
        fileSystem.addExecutable(uvURL, contents: "uv")
    }

    var layout: ManagedRuntimeLayout {
        ManagedRuntimeLayout(applicationSupportDirectoryURL: supportURL)
    }

    func seedValidManagedRuntime() {
        for copy in assets.copies {
            try! fileSystem.copyItem(
                at: copy.source,
                to: layout.projectURL.appendingPathComponent(copy.name)
            )
        }
        try! fileSystem.makeExecutable(at: layout.uvURL)
        fileSystem.addExecutable(layout.environmentPythonURL, contents: "python")
        try! fileSystem.write(Data("ready\n".utf8), to: layout.readyMarkerURL)
    }
}
