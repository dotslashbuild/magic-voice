//
//  NotchShapeTests.swift
//  magic-voiceTests
//
//  Magic Voice — geometry tests for the pure NotchShape.
//

import CoreGraphics
import Testing
@testable import Magic_Voice

struct NotchShapeTests {
    @Test
    func pathIsNonEmptyWithinBounds() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let shape = NotchShape(topCornerRadius: 8, bottomCornerRadius: 14)
        let path = shape.path(in: rect)

        #expect(!path.isEmpty)

        // The generated path must stay within the rect it was asked to fill.
        let bounds = path.boundingRect
        #expect(bounds.minX >= rect.minX - 0.001)
        #expect(bounds.minY >= rect.minY - 0.001)
        #expect(bounds.maxX <= rect.maxX + 0.001)
        #expect(bounds.maxY <= rect.maxY + 0.001)

        // A real shape should occupy meaningful area, not collapse to a point.
        #expect(bounds.width > rect.width / 2)
        #expect(bounds.height > rect.height / 2)
    }

    @Test
    func radiiAreClampedForTinyRects() {
        // Radii larger than the rect must not produce a degenerate/empty path.
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let shape = NotchShape(topCornerRadius: 999, bottomCornerRadius: 999)
        let path = shape.path(in: rect)

        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(bounds.maxX <= rect.maxX + 0.001)
        #expect(bounds.maxY <= rect.maxY + 0.001)
    }
}
