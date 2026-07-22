//
//  ManagedRuntimeProvisionerTests.swift
//  magic-voiceTests
//


import Testing
@testable import Magic_Voice

@MainActor
struct ManagedRuntimeProvisionerTests {

    @Test
    func provisionsLockedEnvironmentAndCopiesEveryAsset() async {
        let harness = RuntimeTestHarness()
        let fileSystem = harness.fileSystem
        let environmentPythonURL = harness.layout.environmentPythonURL
        let runner = FakeRuntimeProcessRunner(
            results: [RuntimeProcessResult(exitCode: 0, standardError: "")],
            onRun: { result in
                if result.exitCode == 0 {
                    fileSystem.addExecutable(environmentPythonURL, contents: "python")
                }
            }
        )
        let provisioner = ManagedRuntimeProvisioner(
            bundle: harness.bundle,
            applicationSupportDirectoryURL: harness.supportURL,
            fileSystem: harness.fileSystem,
            processRunner: runner
        )

        #expect(await provisioner.provision() == .provisioned)
        #expect(provisioner.state == .ready)
        #expect(runner.callCount == 1)
        #expect(runner.lastRequest?.arguments == [
            "sync", "--project", "/support/Sidecar", "--frozen",
            "--managed-python", "--python", "3.12"
        ])
        #expect(harness.fileSystem.fileExists(at: harness.layout.sidecarScriptURL))
        #expect(harness.fileSystem.fileExists(at: harness.layout.projectURL.appendingPathComponent("pyproject.toml")))
        #expect(harness.fileSystem.fileExists(at: harness.layout.projectURL.appendingPathComponent("uv.lock")))
        #expect(harness.fileSystem.isExecutableFile(at: harness.layout.uvURL))
        #expect(harness.fileSystem.fileExists(at: harness.layout.readyMarkerURL))
    }

    @Test
    func validEnvironmentIsFastNoOp() async {
        let harness = RuntimeTestHarness()
        harness.seedValidManagedRuntime()
        let runner = FakeRuntimeProcessRunner(results: [])
        let provisioner = ManagedRuntimeProvisioner(
            bundle: harness.bundle,
            applicationSupportDirectoryURL: harness.supportURL,
            fileSystem: harness.fileSystem,
            processRunner: runner
        )

        #expect(await provisioner.provision() == .alreadyProvisioned)
        #expect(provisioner.state == .ready)
        #expect(runner.callCount == 0)
    }

    @Test
    func failedProvisionCanBeRetried() async {
        let harness = RuntimeTestHarness()
        let fileSystem = harness.fileSystem
        let environmentPythonURL = harness.layout.environmentPythonURL
        let runner = FakeRuntimeProcessRunner(
            results: [
                RuntimeProcessResult(exitCode: 2, standardError: "network unavailable"),
                RuntimeProcessResult(exitCode: 0, standardError: "")
            ],
            onRun: { result in
                if result.exitCode == 0 {
                    fileSystem.addExecutable(environmentPythonURL, contents: "python")
                }
            }
        )
        let provisioner = ManagedRuntimeProvisioner(
            bundle: harness.bundle,
            applicationSupportDirectoryURL: harness.supportURL,
            fileSystem: harness.fileSystem,
            processRunner: runner
        )

        #expect(await provisioner.provision() == .failed(message: "Runtime setup failed: network unavailable"))
        #expect(provisioner.state == .failed(message: "Runtime setup failed: network unavailable"))
        #expect(await provisioner.provision() == .provisioned)
        #expect(provisioner.state == .ready)
        #expect(runner.callCount == 2)
    }

    @Test
    func emitsProvisioningProgressInOrder() async {
        let harness = RuntimeTestHarness()
        let fileSystem = harness.fileSystem
        let environmentPythonURL = harness.layout.environmentPythonURL
        var progress: [ManagedRuntimeProvisioningProgress] = []
        let runner = FakeRuntimeProcessRunner(
            results: [RuntimeProcessResult(exitCode: 0, standardError: "")],
            onRun: { _ in
                fileSystem.addExecutable(environmentPythonURL, contents: "python")
            }
        )
        let provisioner = ManagedRuntimeProvisioner(
            bundle: harness.bundle,
            applicationSupportDirectoryURL: harness.supportURL,
            fileSystem: harness.fileSystem,
            processRunner: runner,
            progressHandler: { progress.append($0) }
        )

        _ = await provisioner.provision()

        #expect(progress == [.preparing, .copyingAssets, .synchronizingEnvironment])
    }
}
