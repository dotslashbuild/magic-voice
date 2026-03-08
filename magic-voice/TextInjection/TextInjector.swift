//
//  TextInjector.swift
//  magic-voice
//
//  Magic Voice — AX-first text insertion with clipboard-preserving paste fallback.
//
//  This file is a thin Observable facade over FallbackInjector. RecordingController
//  and the rest of the app call `inject(_:)` and observe `lastMethod`/`lastError`
//  exactly as before; the injection logic lives in the typed adapters below.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class TextInjector: ObservableObject {
    @Published private(set) var lastMethod: InjectionMethod = .none
    @Published private(set) var isPendingDelayedInjection = false
    @Published private(set) var lastError: String?
    /// The full result of the most-recent injection attempt, for debug views.
    @Published private(set) var lastResult: InjectionResult?

    private let permissionController: PermissionController
    private let injector: FallbackInjector
    private var delayedInjectionTask: Task<Void, Never>?

    init(
        permissionController: PermissionController,
        injector: FallbackInjector? = nil
    ) {
        self.permissionController = permissionController
        self.injector = injector ?? FallbackInjector(
            primary: AccessibilityInjector(),
            fallback: ClipboardPasteInjector()
        )
    }

    func injectTestText() {
        inject("Magic Voice test")
    }

    func injectTestTextAfterDelay() {
        delayedInjectionTask?.cancel()
        isPendingDelayedInjection = true
        lastError = nil

        delayedInjectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                self?.isPendingDelayedInjection = false
                self?.inject("Magic Voice test")
            }
        }
    }

    func cancelDelayedInjection() {
        delayedInjectionTask?.cancel()
        delayedInjectionTask = nil
        isPendingDelayedInjection = false
    }

    func inject(_ text: String) {
        guard !text.isEmpty else { return }

        permissionController.refresh()
        guard permissionController.status(for: .accessibility).isGranted else {
            lastMethod = .failed
            lastError = "Grant Accessibility to insert text"
            lastResult = .failure(reason: "Grant Accessibility to insert text", text: text)
            permissionController.request(.accessibility)
            return
        }

        lastError = nil
        let result = injector.inject(text)
        lastResult = result

        // Update legacy `lastMethod` for callers / existing debug UI.
        switch result.adapter {
        case .accessibility:
            lastMethod = result.succeeded ? .accessibility : .failed
        case .clipboardPaste:
            lastMethod = result.succeeded ? .pasteFallback : .failed
        case .none:
            lastMethod = .failed
        }

        if !result.succeeded {
            lastError = result.skipReason
        }
    }
}

// MARK: - Legacy method enum (kept for RecordingController compatibility)

enum InjectionMethod: String {
    case none = "None"
    case accessibility = "AX"
    case pasteFallback = "Paste"
    case failed = "Failed"
}

// MARK: - ClipboardRestorer (shared utility, referenced by ClipboardPasteInjector)

final class ClipboardRestorer: @unchecked Sendable {
    struct Snapshot: Sendable {
        let items: [[ArchivedPasteboardItem]]
    }

    struct ArchivedPasteboardItem: Sendable {
        let typeRawValue: String
        let data: Data
    }

    func snapshot() -> Snapshot {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems ?? []
        let archivedItems = items.map { item in
            item.types.compactMap { type -> ArchivedPasteboardItem? in
                guard let data = item.data(forType: type) else { return nil }
                return ArchivedPasteboardItem(typeRawValue: type.rawValue, data: data)
            }
        }
        return Snapshot(items: archivedItems)
    }

    func restore(_ snapshot: Snapshot, after delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            let items = snapshot.items.map { archivedItem in
                let item = NSPasteboardItem()
                for payload in archivedItem {
                    item.setData(payload.data, forType: NSPasteboard.PasteboardType(payload.typeRawValue))
                }
                return item
            }

            if !items.isEmpty {
                pasteboard.writeObjects(items)
            }
        }
    }
}
