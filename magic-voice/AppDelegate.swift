//
//  AppDelegate.swift
//  magic-voice
//
//  Magic Voice — NSApplication delegate. Promotes the app to a menu bar agent
//  (no Dock icon, no app switcher entry) at runtime so the Info.plist
//  LSUIElement key is not strictly required during early development.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard let launchMode = parseSidecarSmokeLaunchMode(
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            return
        }

        Task { @MainActor in
            let sink = StandardSidecarSmokeExitSink()
            let provisioner = ManagedRuntimeProvisioner()
            if provisioner.requiresProvisioning {
                let provisioningResult = await provisioner.provision()
                guard provisioningResult == .provisioned
                        || provisioningResult == .alreadyProvisioned else {
                    let reason: String
                    if case .failed(let message) = provisioningResult {
                        reason = message
                    } else {
                        reason = "managed runtime provisioning did not complete"
                    }
                    sink.finish(with: SidecarSmokeResult(
                        passed: false,
                        reason: "runtime provisioning failed: \(reason)"
                    ))
                    return
                }
            }

            guard let harness = makeProductionSidecarSmokeHarness(
                launchMode: launchMode,
                exitSink: sink
            ) else {
                sink.finish(with: SidecarSmokeResult(
                    passed: false,
                    reason: "sidecar.py not found in the app bundle"
                ))
                return
            }

            await harness.run()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
