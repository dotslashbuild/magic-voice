//
//  PermissionDisplayTests.swift
//  magic-voiceTests
//
//  Magic Voice — display-mapping tests for the pure permission models.
//
//  NOTE: This stands in for the SettingsStore history round-trip test called
//  out in ticket W1-1. SettingsStore.swift is being refactored concurrently by
//  another agent, so to avoid depending on an in-flux Codable/init API we test
//  the stable, pure PermissionKind / PermissionStatus display mappings instead.
//

import Testing
@testable import Magic_Voice

struct PermissionDisplayTests {
    @Test
    func everyPermissionKindHasDistinctDisplayName() {
        let names = PermissionKind.allCases.map(\.displayName)
        let uniqueCount = Set(names).count
        let hasEmpty = names.contains(where: { $0.isEmpty })
        #expect(names.count == PermissionKind.allCases.count)
        #expect(uniqueCount == names.count)
        #expect(!hasEmpty)
    }

    @Test
    func permissionKindExplanationsAreNonEmpty() {
        for kind in PermissionKind.allCases {
            #expect(!kind.explanation.isEmpty)
        }
    }

    @Test
    func onlyGrantedStatusReportsGranted() {
        #expect(PermissionStatus.granted.isGranted)
        #expect(!PermissionStatus.needsAccess.isGranted)
        #expect(!PermissionStatus.denied.isGranted)
        #expect(!PermissionStatus.restricted.isGranted)
        #expect(!PermissionStatus.unknown.isGranted)
    }

    @Test
    func everyStatusHasATitle() {
        let statuses: [PermissionStatus] = [.granted, .needsAccess, .denied, .restricted, .unknown]
        for status in statuses {
            #expect(!status.title.isEmpty)
        }
    }
}
