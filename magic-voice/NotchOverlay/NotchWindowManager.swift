//
//  NotchWindowManager.swift
//  magic-voice
//
//  Magic Voice — floating NSPanel lifecycle and notch geometry.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowManager: ObservableObject {
    static let waveformBarCount = 8

    @Published private(set) var state: NotchState = .collapsed
    @Published var liveTranscript: String = ""
    @Published private(set) var audioLevels: [Double] = Array(repeating: 0, count: NotchWindowManager.waveformBarCount)
    @Published private(set) var notchBaseWidth: CGFloat = 126
    @Published private(set) var notchBaseHeight: CGFloat = 32
    @Published private(set) var hasHardwareNotch = false

    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var collapseTask: Task<Void, Never>?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPanelFrame()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func transition(to newState: NotchState, transcript: String? = nil) {
        collapseTask?.cancel()
        if let transcript {
            liveTranscript = transcript
        }

        ensurePanel()
        refreshPanelFrame()
        if newState == .active {
            resetAudioLevels()
        }
        state = newState
        panel?.alphaValue = newState == .collapsed ? 0 : 1

        if newState != .collapsed {
            panel?.orderFrontRegardless()
        }

        if newState == .finished {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run {
                    self?.transition(to: .collapsed)
                }
            }
        }
    }

    /// Feed one mic level sample (0...1). The newest sample scrolls in on the
    /// right with a fast attack and slow decay so the bars track speech energy
    /// without jittering.
    func pushAudioLevel(_ level: Double) {
        guard state != .collapsed else { return }

        let previous = audioLevels.last ?? 0
        let smoothed = level >= previous ? level : max(level, previous * 0.72)
        audioLevels.removeFirst()
        audioLevels.append(min(max(smoothed, 0), 1))
    }

    func resetAudioLevels() {
        audioLevels = Array(repeating: 0, count: Self.waveformBarCount)
    }

    func updateTranscript(_ text: String) {
        liveTranscript = text
        if state == .active || state == .collapsed {
            transition(to: .liveText)
        }
    }

    func hide() {
        transition(to: .collapsed)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchRecorderView().environmentObject(self))
        panel.alphaValue = 0

        self.panel = panel
    }

    private func refreshPanelFrame() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let metrics = calculateWindowMetrics(for: screen)
        notchBaseWidth = metrics.notchWidth
        notchBaseHeight = metrics.notchHeight
        hasHardwareNotch = metrics.hasHardwareNotch
        panel.setFrame(NSRect(origin: metrics.origin, size: metrics.size), display: true)
    }

    private func calculateWindowMetrics(for screen: NSScreen) -> (origin: CGPoint, size: CGSize, notchWidth: CGFloat, notchHeight: CGFloat, hasHardwareNotch: Bool) {
        let hasNotch = screen.safeAreaInsets.top > 0
        let notchHeight = hasNotch ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        let notchWidth = calculatedNotchWidth(for: screen, hasNotch: hasNotch)
        let maxWidth = min(screen.frame.width - 32, notchWidth + 260)
        let maxHeight = notchHeight + 72
        let originX = screen.frame.midX - maxWidth / 2
        let originY = screen.frame.maxY - maxHeight

        return (
            CGPoint(x: originX, y: originY),
            CGSize(width: maxWidth, height: maxHeight),
            notchWidth,
            notchHeight,
            hasNotch
        )
    }

    private func calculatedNotchWidth(for screen: NSScreen, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return 168 }

        if let leftWidth = screen.auxiliaryTopLeftArea?.width,
           let rightWidth = screen.auxiliaryTopRightArea?.width {
            let width = screen.frame.width - leftWidth - rightWidth
            if width > 0 {
                return width
            }
        }

        return 180
    }
}
