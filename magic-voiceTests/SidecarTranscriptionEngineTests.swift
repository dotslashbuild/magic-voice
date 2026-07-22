//
//  SidecarTranscriptionEngineTests.swift
//  magic-voiceTests
//


import Testing
@testable import Magic_Voice

struct SidecarTranscriptionEngineTests {
    @Test
    func processEnvironmentStripsMetalValidationAndHardensPython() {
        let metalKeys = [
            "MTL_DEBUG_LAYER",
            "METAL_DEVICE_WRAPPER_TYPE",
            "METAL_DEBUG_ERROR_MODE",
            "METAL_DEBUG_ENFORCE_VALIDATION",
            "METAL_CAPTURE_ENABLED",
            "MTL_CAPTURE_ENABLED"
        ]
        var base = Dictionary(uniqueKeysWithValues: metalKeys.map { ($0, "injected") })
        base["PRESERVED"] = "base"

        let environment = makeSidecarProcessEnvironment(
            base: base,
            overrides: [
                "PRESERVED": "override",
                "MTL_DEBUG_LAYER": "reintroduced",
                "PYTHONNOUSERSITE": "0",
                "PYTHONUNBUFFERED": "0"
            ]
        )

        for key in metalKeys {
            #expect(environment[key] == nil)
        }
        #expect(environment["PRESERVED"] == "override")
        #expect(environment["PYTHONNOUSERSITE"] == "1")
        #expect(environment["PYTHONUNBUFFERED"] == "1")
    }

    @Test
    func cancelStreamCommandCarriesActiveRequestID() {
        #expect(SidecarJSONLinesMessage.cancelStream(requestID: "session-42") ==
            SidecarJSONLinesMessage([
                "type": "cancel_stream",
                "request_id": "session-42"
            ]))
    }
}
