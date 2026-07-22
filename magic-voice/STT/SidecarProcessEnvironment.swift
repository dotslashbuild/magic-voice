//
//  SidecarProcessEnvironment.swift
//  magic-voice
//
//  Pure construction of the Python child environment.
//

import Foundation

nonisolated func makeSidecarProcessEnvironment(
    base: [String: String],
    overrides: [String: String] = [:]
) -> [String: String] {
    let metalEnvironmentKeys = [
        "MTL_DEBUG_LAYER",
        "METAL_DEVICE_WRAPPER_TYPE",
        "METAL_DEBUG_ERROR_MODE",
        "METAL_DEBUG_ENFORCE_VALIDATION",
        "METAL_CAPTURE_ENABLED",
        "MTL_CAPTURE_ENABLED"
    ]
    var environment = base.merging(overrides) { _, override in override }
    for key in metalEnvironmentKeys {
        environment.removeValue(forKey: key)
    }
    environment["PYTHONNOUSERSITE"] = "1"
    environment["PYTHONUNBUFFERED"] = "1"
    return environment
}
