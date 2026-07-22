//
//  SidecarRuntimeLocatorTests.swift
//  magic-voiceTests
//
//  Magic Voice — runtime locator coverage without modifying the developer machine.
//

import Foundation
import Testing
@testable import Magic_Voice

@MainActor
struct SidecarRuntimeLocatorTests {

    @Test
    func findsUvFromPathBeforeStandardCandidates() throws {
        let scriptURL = URL(fileURLWithPath: "/repo/sidecar/sidecar.py")
        let locator = DevelopmentUvLocator(
            environmentPath: "/custom/bin",
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/custom/bin/uv" }
        )

        guard case .ready(let plan) = locator.locate(scriptURL: scriptURL, model: .nemotronStreaming06B, language: "en") else {
            Issue.record("Expected uv launch plan")
            return
        }

        #expect(plan.executableURL.path == "/custom/bin/uv")
        #expect(plan.arguments == [
            "run",
            "--frozen",
            "python",
            "/repo/sidecar/sidecar.py",
            "--model",
            STTModel.nemotronStreaming06B.hubID,
            "--language",
            "en"
        ])
        #expect(plan.workingDirectoryURL.path == "/repo/sidecar")
    }

    @Test
    func findsUvAtEachStandardCandidate() {
        let scriptURL = URL(fileURLWithPath: "/repo/sidecar/sidecar.py")
        let candidates = [
            "/Users/test/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv"
        ]

        for candidate in candidates {
            let locator = DevelopmentUvLocator(
                environmentPath: "",
                homeDirectory: "/Users/test",
                isExecutable: { $0 == candidate }
            )

            guard case .ready(let plan) = locator.locate(scriptURL: scriptURL, model: .nemotronStreaming06B, language: "auto") else {
                Issue.record("Expected uv launch plan for \(candidate)")
                continue
            }

            #expect(plan.executableURL.path == candidate)
            #expect(plan.arguments.prefix(3) == ["run", "--frozen", "python"])
        }
    }

    @Test
    func fallsBackToPython3WhenUvIsMissing() {
        let scriptURL = URL(fileURLWithPath: "/repo/sidecar/sidecar.py")
        let locator = DevelopmentUvLocator(
            environmentPath: "",
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/usr/bin/python3" }
        )

        guard case .ready(let plan) = locator.locate(scriptURL: scriptURL, model: .nemotronStreaming06B8Bit, language: "fr") else {
            Issue.record("Expected python launch plan")
            return
        }

        #expect(plan.executableURL.path == "/usr/bin/python3")
        #expect(plan.arguments == [
            "/repo/sidecar/sidecar.py",
            "--model",
            STTModel.nemotronStreaming06B8Bit.hubID,
            "--language",
            "fr"
        ])
    }

    @Test
    func reportsNeedsInstallWhenNoRuntimeExists() {
        let scriptURL = URL(fileURLWithPath: "/repo/sidecar/sidecar.py")
        let locator = DevelopmentUvLocator(
            environmentPath: "",
            homeDirectory: "/Users/test",
            isExecutable: { _ in false }
        )

        #expect(locator.locate(scriptURL: scriptURL, model: .nemotronStreaming06B, language: "auto") == .needsInstall(
            message: "Install uv to run the transcription sidecar: brew install uv"
        ))
    }

    @Test
    func bundledRuntimeSignalsThatProvisioningIsNeeded() {
        let harness = RuntimeTestHarness()
        let locator = BundledRuntimeLocator(
            bundle: harness.bundle,
            applicationSupportDirectoryURL: harness.supportURL,
            fileSystem: harness.fileSystem
        )

        #expect(locator.locate(
            scriptURL: URL(fileURLWithPath: "/ignored/sidecar.py"),
            model: .nemotronStreaming06B,
            language: "auto",
            mode: .serve
        ) == .needsInstall(message: "Magic Voice is preparing its managed transcription runtime."))
    }

    @Test
    func bundledRuntimeResolvesManagedLaunchPlan() {
        let harness = RuntimeTestHarness()
        harness.seedValidManagedRuntime()
        let locator = BundledRuntimeLocator(
            bundle: harness.bundle,
            applicationSupportDirectoryURL: harness.supportURL,
            fileSystem: harness.fileSystem
        )

        guard case .ready(let plan) = locator.locate(
            scriptURL: URL(fileURLWithPath: "/ignored/sidecar.py"),
            model: .nemotronStreaming06B8Bit,
            language: "fr",
            mode: .downloadModel
        ) else {
            Issue.record("Expected bundled runtime launch plan")
            return
        }

        #expect(plan.executableURL.path == "/support/Sidecar/uv")
        #expect(plan.workingDirectoryURL.path == "/support/Sidecar")
        #expect(plan.arguments == [
            "--project", "/support/Sidecar",
            "run", "--frozen", "--managed-python", "--python", "3.12", "python",
            "/support/Sidecar/sidecar.py",
            "--model", STTModel.nemotronStreaming06B8Bit.hubID,
            "--language", "fr",
            "--download-model"
        ])
        #expect(plan.environment["UV_PROJECT_ENVIRONMENT"] == "/support/Sidecar/.venv")
        #expect(plan.environment["HF_HOME"] == "/support/ModelCache/huggingface")
    }
}
