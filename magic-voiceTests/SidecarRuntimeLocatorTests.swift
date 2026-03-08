//
//  SidecarRuntimeLocatorTests.swift
//  magic-voiceTests
//
//  Magic Voice — runtime locator coverage without modifying the developer machine.
//

import Foundation
import Testing
@testable import Magic_Voice

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
    func managedUvCopiesLockedProjectIntoApplicationSupport() throws {
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("ManagedUvRuntimeLocatorTests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = tempURL.appendingPathComponent("source", isDirectory: true)
        let supportURL = tempURL.appendingPathComponent("support", isDirectory: true)
        let uvURL = tempURL.appendingPathComponent("uv")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: uvURL, atomically: true, encoding: .utf8)
        try "print('ok')\n".write(to: sourceURL.appendingPathComponent("sidecar.py"), atomically: true, encoding: .utf8)
        try "[project]\nname = \"sidecar\"\n".write(to: sourceURL.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        try "version = 1\n".write(to: sourceURL.appendingPathComponent("uv.lock"), atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: tempURL) }

        let locator = ManagedUvRuntimeLocator(
            bundledUvURL: uvURL,
            applicationSupportDirectoryURL: supportURL,
            isExecutable: { $0 == uvURL.path }
        )

        guard case .ready(let plan) = locator.locate(
            scriptURL: sourceURL.appendingPathComponent("sidecar.py"),
            model: .nemotronStreaming06B,
            language: "auto",
            mode: .downloadModel
        ) else {
            Issue.record("Expected managed uv launch plan")
            return
        }

        let managedProjectURL = supportURL.appendingPathComponent("Sidecar", isDirectory: true)
        #expect(fileManager.fileExists(atPath: managedProjectURL.appendingPathComponent("sidecar.py").path))
        #expect(fileManager.fileExists(atPath: managedProjectURL.appendingPathComponent("pyproject.toml").path))
        #expect(fileManager.fileExists(atPath: managedProjectURL.appendingPathComponent("uv.lock").path))
        #expect(plan.executableURL == uvURL)
        #expect(plan.arguments.contains("--frozen"))
        #expect(plan.arguments.contains("--managed-python"))
        #expect(plan.arguments.contains("--download-model"))
        #expect(plan.environment["UV_PROJECT_ENVIRONMENT"] == supportURL.appendingPathComponent("Sidecar/.venv").path)
        #expect(plan.environment["HF_HOME"] == supportURL.appendingPathComponent("ModelCache/huggingface").path)
    }
}
