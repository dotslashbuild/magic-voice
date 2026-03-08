//
//  render_app_icon.swift
//  Renders the Magic Voice app icon (Voice orb) at every macOS size into
//  the asset catalog. Run from anywhere:
//      swift scripts/render_app_icon.swift
//

import AppKit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconsetPath = repoRoot.appendingPathComponent("magic-voice/Assets.xcassets/AppIcon.appiconset").path

// Palette: monochromatic — every color is the background indigo hue (~245°)
// at a different lightness.
let background = NSColor(srgbRed: 0x26 / 255.0, green: 0x21 / 255.0, blue: 0x5C / 255.0, alpha: 1)
let ringColor  = NSColor(srgbRed: 0x7E / 255.0, green: 0x76 / 255.0, blue: 0xC8 / 255.0, alpha: 1)
let barBright  = NSColor(srgbRed: 0xB3 / 255.0, green: 0xAC / 255.0, blue: 0xEC / 255.0, alpha: 1)
let barSoft    = NSColor(srgbRed: 0x8E / 255.0, green: 0x86 / 255.0, blue: 0xD4 / 255.0, alpha: 1)

/// Draws the icon into a `canvas`-pt square coordinate system.
/// Layout follows the macOS icon grid: content card is 80.5% of the
/// canvas, centered. All geometry is proportional so every size renders
/// from the same description.
/// Note: sizes ≤32px are intentionally approximate (sub-pixel strokes); the identity reads cleanly from 128px up.
func drawIcon(canvas: CGFloat) {
    let cardSide = canvas * 0.805
    let cardOrigin = (canvas - cardSide) / 2
    let card = NSRect(x: cardOrigin, y: cardOrigin, width: cardSide, height: cardSide)

    background.setFill()
    NSBezierPath(roundedRect: card, xRadius: cardSide * 0.225, yRadius: cardSide * 0.225).fill()

    let center = NSPoint(x: canvas / 2, y: canvas / 2)
    let orbRadius = cardSide * 0.36

    ringColor.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(
        x: center.x - orbRadius, y: center.y - orbRadius,
        width: orbRadius * 2, height: orbRadius * 2
    ))
    ring.lineWidth = cardSide * 0.045
    ring.stroke()

    // Five waveform bars: relative heights and colors, centered in the orb.
    let bars: [(height: CGFloat, color: NSColor)] = [
        (0.30, barSoft), (0.54, barBright), (0.40, barSoft), (0.62, barBright), (0.22, barSoft),
    ]
    let barWidth = cardSide * 0.052
    let spacing = cardSide * 0.092
    let totalWidth = CGFloat(bars.count - 1) * spacing + barWidth
    var x = center.x - totalWidth / 2
    for bar in bars {
        let height = cardSide * bar.height
        bar.color.setFill()
        let rect = NSRect(x: x, y: center.y - height / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += spacing
    }
}

func renderPNG(pixels: Int, to filename: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Could not create bitmap rep for \(pixels)px") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(canvas: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for \(pixels)px")
    }
    let url = URL(fileURLWithPath: "\(iconsetPath)/\(filename)")
    try! data.write(to: url)
    print("wrote \(url.path)")
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    renderPNG(pixels: pixels, to: "icon_\(pixels).png")
}

let contents = """
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(
    to: URL(fileURLWithPath: "\(iconsetPath)/Contents.json"),
    atomically: true, encoding: .utf8
)
print("wrote \(iconsetPath)/Contents.json")
