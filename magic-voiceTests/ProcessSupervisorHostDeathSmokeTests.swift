//
//  ProcessSupervisorHostDeathSmokeTests.swift
//  magic-voiceTests
//

import Foundation
import Testing
@testable import Magic_Voice

@Suite("Process supervisor host-death smoke arguments")
struct ProcessSupervisorHostDeathSmokeTests {
    @Test("Parses fixture and state paths")
    func parsesRequest() {
        let request = parseProcessSupervisorHostDeathSmokeRequest(arguments: [
            "Magic Voice",
            "--process-supervisor-host-death-smoke",
            "/tmp/fixture",
            "/tmp/state"
        ])

        #expect(request == ProcessSupervisorHostDeathSmokeRequest(
            fixtureURL: URL(fileURLWithPath: "/tmp/fixture"),
            stateDirectoryURL: URL(fileURLWithPath: "/tmp/state")
        ))
    }

    @Test("Rejects missing values")
    func rejectsMissingValues() {
        #expect(parseProcessSupervisorHostDeathSmokeRequest(arguments: [
            "Magic Voice", "--process-supervisor-host-death-smoke", "/tmp/fixture"
        ]) == nil)
    }
}
