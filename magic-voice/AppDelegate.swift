//
//  AppDelegate.swift
//  magic-voice
//
//  Magic Voice — NSApplication delegate. Promotes the app to a menu bar agent
//  (no Dock icon, no app switcher entry) at runtime so the Info.plist
//  LSUIElement key is not strictly required during early development.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
