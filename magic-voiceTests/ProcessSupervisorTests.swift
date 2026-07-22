//
//  ProcessSupervisorTests.swift
//  magic-voiceTests
//

import Foundation
import Testing
@testable import Magic_Voice

@Suite("Process supervisor launch plan")
struct ProcessSupervisorTests {
    @Test("Wraps an absolute executable without shell construction")
    func wrapsAbsoluteExecutable() throws {
        let helper = URL(fileURLWithPath: "/Applications/Magic Voice.app/Contents/MacOS/MagicVoiceProcessSupervisor")
        let command = URL(fileURLWithPath: "/usr/bin/printf")

        let plan = try SupervisedProcessLaunchPlan.wrapping(
            executableURL: command,
            arguments: ["%s", "hello; touch /tmp/not-a-command"],
            supervisorURL: helper,
            parentPID: 4321
        )

        #expect(plan.executableURL == helper)
        #expect(plan.arguments == [
            "--parent-pid", "4321", "--", "/usr/bin/printf",
            "%s", "hello; touch /tmp/not-a-command"
        ])
    }

    @Test("Rejects a relative executable")
    func rejectsRelativeExecutable() {
        #expect(throws: ProcessSupervisorError.self) {
            try SupervisedProcessLaunchPlan.wrapping(
                executableURL: URL(string: "relative/tool")!,
                arguments: [],
                supervisorURL: URL(fileURLWithPath: "/tmp/supervisor"),
                parentPID: 4321
            )
        }
    }

    @Test("Rejects an invalid parent PID")
    func rejectsInvalidParentPID() {
        #expect(throws: ProcessSupervisorError.self) {
            try SupervisedProcessLaunchPlan.wrapping(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                supervisorURL: URL(fileURLWithPath: "/tmp/supervisor"),
                parentPID: 1
            )
        }
    }
}
