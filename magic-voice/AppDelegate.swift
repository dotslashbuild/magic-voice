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

        guard parseSidecarSmokeLaunchMode(arguments: ProcessInfo.processInfo.arguments) != nil else {
            return
        }

        guard let harness = makeProductionSidecarSmokeHarness() else {
            StandardSidecarSmokeExitSink().finish(with: SidecarSmokeResult(
                passed: false,
                reason: "sidecar.py not found in the app bundle"
            ))
            return
        }

        Task { await harness.run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
