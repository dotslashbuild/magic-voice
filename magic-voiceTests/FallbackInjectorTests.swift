//
//  FallbackInjectorTests.swift
//  magic-voiceTests
//
//  Magic Voice — unit tests for FallbackInjector using stubbed adapters.
//
//  AX and clipboard system calls cannot run headless, so the real adapters are
//  NOT tested here. Instead, lightweight stubs conforming to TextInjecting let
//  us exercise every branch of FallbackInjector's composite policy.
//

import Testing
@testable import Magic_Voice

// MARK: - Test stubs

/// A stub adapter whose outcome is configured at construction time.
@MainActor
private final class StubInjector: TextInjecting {
    private let result: InjectionResult
    private(set) var callCount = 0
    private(set) var lastReceivedText: String?

    init(result: InjectionResult) {
        self.result = result
    }

    func inject(_ text: String) -> InjectionResult {
        callCount += 1
        lastReceivedText = text
        // Return the configured result but with the actual received text recorded.
        return InjectionResult(
            adapter: result.adapter,
            succeeded: result.succeeded,
            skipReason: result.skipReason,
            injectedText: text
        )
    }
}

// MARK: - Tests

@MainActor
struct FallbackInjectorTests {

    // MARK: Primary succeeds

    @Test
    func primarySucceeds_returnsAccessibilityResult_noFallback() async throws {
        let primary = StubInjector(result: .success(adapter: .accessibility, text: ""))
        let fallback = StubInjector(result: .success(adapter: .clipboardPaste, text: ""))

        let sut = FallbackInjector(primary: primary, fallback: fallback)
        let result = sut.inject("Hello")

        #expect(result.adapter == .accessibility)
        #expect(result.succeeded == true)
        #expect(result.skipReason == nil)
        #expect(result.injectedText == "Hello")

        // Fallback must not have been called.
        #expect(fallback.callCount == 0)
        #expect(primary.callCount == 1)
    }

    // MARK: Primary fails → fallback runs

    @Test
    func primaryFails_fallbackRuns_resultCarriesSkipReason() async throws {
        let primary = StubInjector(
            result: InjectionResult(
                adapter: .accessibility,
                succeeded: false,
                skipReason: "No writable AX element in focus",
                injectedText: ""
            )
        )
        let fallback = StubInjector(result: .success(adapter: .clipboardPaste, text: ""))

        let sut = FallbackInjector(primary: primary, fallback: fallback)
        let result = sut.inject("World")

        // Fallback adapter is used.
        #expect(result.adapter == .clipboardPaste)
        #expect(result.succeeded == true)
        // Skip reason from the primary failure is preserved.
        #expect(result.skipReason == "No writable AX element in focus")
        #expect(result.injectedText == "World")

        #expect(primary.callCount == 1)
        #expect(fallback.callCount == 1)
        #expect(fallback.lastReceivedText == "World")
    }

    @Test
    func primaryFails_fallbackAlsoFails_resultReportsFailure() async throws {
        let primary = StubInjector(
            result: InjectionResult(
                adapter: .accessibility,
                succeeded: false,
                skipReason: "AX denied",
                injectedText: ""
            )
        )
        let fallback = StubInjector(
            result: InjectionResult(
                adapter: .clipboardPaste,
                succeeded: false,
                skipReason: nil,
                injectedText: ""
            )
        )

        let sut = FallbackInjector(primary: primary, fallback: fallback)
        let result = sut.inject("Oops")

        #expect(result.adapter == .clipboardPaste)
        #expect(result.succeeded == false)
        // Primary skip reason must be threaded through even when fallback also fails.
        #expect(result.skipReason == "AX denied")
        #expect(result.injectedText == "Oops")

        #expect(primary.callCount == 1)
        #expect(fallback.callCount == 1)
    }

    // MARK: Empty text guard

    @Test
    func emptyText_returnsFailureImmediately_neitherAdapterCalled() async throws {
        let primary = StubInjector(result: .success(adapter: .accessibility, text: ""))
        let fallback = StubInjector(result: .success(adapter: .clipboardPaste, text: ""))

        let sut = FallbackInjector(primary: primary, fallback: fallback)
        let result = sut.inject("")

        #expect(result.succeeded == false)
        #expect(result.adapter == .none)
        #expect(primary.callCount == 0)
        #expect(fallback.callCount == 0)
    }

    // MARK: injectedText round-trip (forward-compatibility for B2 retract/retype)

    @Test
    func injectedText_isPreservedInResult_forFutureRevision() async throws {
        let primary = StubInjector(result: .success(adapter: .accessibility, text: ""))
        let sut = FallbackInjector(primary: primary, fallback: StubInjector(result: .success(adapter: .clipboardPaste, text: "")))

        let injected = "Draft sentence for revision."
        let result = sut.inject(injected)

        // The injected text must survive in the result so a future "retract/retype"
        // adapter can know exactly what to undo without extra state.
        #expect(result.injectedText == injected)
    }

    // MARK: InjectionResult convenience constructors

    @Test
    func injectionResultSuccess_hasCorrectShape() {
        let r = InjectionResult.success(adapter: .accessibility, text: "hi")
        #expect(r.adapter == .accessibility)
        #expect(r.succeeded == true)
        #expect(r.skipReason == nil)
        #expect(r.injectedText == "hi")
    }

    @Test
    func injectionResultFallback_hasCorrectShape() {
        let r = InjectionResult.fallback(
            adapter: .clipboardPaste,
            succeeded: true,
            skipReason: "AX not available",
            text: "hi"
        )
        #expect(r.adapter == .clipboardPaste)
        #expect(r.succeeded == true)
        #expect(r.skipReason == "AX not available")
        #expect(r.injectedText == "hi")
    }

    @Test
    func injectionResultFailure_hasCorrectShape() {
        let r = InjectionResult.failure(reason: "permission denied", text: "hi")
        #expect(r.adapter == .none)
        #expect(r.succeeded == false)
        #expect(r.skipReason == "permission denied")
        #expect(r.injectedText == "hi")
    }
}
