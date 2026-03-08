//
//  MenuBarGlyph.swift
//  magic-voice
//
//  Magic Voice — the Voice orb as a monochrome menu bar template image.
//  Idle: orb outline + three waveform bars. Recording: filled orb with
//  bars knocked out. Paused: dimmed outline with flat bars.
//

import AppKit

enum MenuBarGlyph {

    static func image(for state: MenuBarStatus.Glyph) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ state: MenuBarStatus.Glyph) {
        let center = NSPoint(x: 9, y: 9)
        let color: NSColor = state == .paused ? NSColor.black.withAlphaComponent(0.4) : .black

        switch state {
        case .idle:
            strokeRing(center: center, radius: 7, color: color)
            fillBars(heights: [4.6, 8.4, 3.6], color: color)

        case .recording:
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15)).fill()
            // Knock the bars out of the filled orb.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            fillBars(heights: [5.4, 9.8, 4.4], color: .black)
            NSGraphicsContext.restoreGraphicsState()

        case .paused:
            strokeRing(center: center, radius: 7, color: color)
            fillBars(heights: [3, 3, 3], color: color)
        }
    }

    private static func strokeRing(center: NSPoint, radius: CGFloat, color: NSColor) {
        color.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    private static func fillBars(heights: [CGFloat], color: NSColor) {
        color.setFill()
        let barWidth: CGFloat = 1.6
        let spacing: CGFloat = 2.8
        let totalWidth = CGFloat(heights.count - 1) * spacing + barWidth
        var x = 9 - totalWidth / 2
        for height in heights {
            let bar = NSRect(x: x, y: 9 - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += spacing
        }
    }
}
