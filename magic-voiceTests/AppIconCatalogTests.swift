//
//  AppIconCatalogTests.swift
//  magic-voiceTests
//

import Foundation
import Testing

struct AppIconCatalogTests {

    @Test
    func everyReferencedIconFileExistsInTheCatalog() throws {
        let iconset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("magic-voice/Assets.xcassets/AppIcon.appiconset")

        struct Contents: Decodable {
            struct Entry: Decodable { let filename: String? }
            let images: [Entry]
        }

        let data = try Data(contentsOf: iconset.appendingPathComponent("Contents.json"))
        let contents = try JSONDecoder().decode(Contents.self, from: data)

        #expect(!contents.images.isEmpty)
        for entry in contents.images {
            let filename = try #require(entry.filename)
            let exists = FileManager.default.fileExists(
                atPath: iconset.appendingPathComponent(filename).path
            )
            #expect(exists, "missing \(filename)")
        }
    }
}
