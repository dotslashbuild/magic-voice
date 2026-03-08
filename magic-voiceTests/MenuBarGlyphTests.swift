//
//  MenuBarGlyphTests.swift
//  magic-voiceTests
//

import AppKit
import Testing
@testable import Magic_Voice

struct MenuBarGlyphTests {

    @Test
    func everyStateRendersAnEighteenPointTemplateImage() {
        for state in [MenuBarStatus.Glyph.idle, .recording, .paused] {
            let image = MenuBarGlyph.image(for: state)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
        }
    }
}
