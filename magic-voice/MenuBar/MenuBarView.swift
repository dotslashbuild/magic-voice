//
//  MenuBarView.swift
//  magic-voice
//
//  Magic Voice — popover control center: status header, conditional
//  health banner, shortcut hint, quick controls, recent transcripts.
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var notchManager: NotchWindowManager
    @EnvironmentObject private var permissionController: PermissionController
    @EnvironmentObject private var audioCaptureManager: AudioCaptureManager
    @EnvironmentObject private var dictationSession: DictationSession
    @EnvironmentObject private var transcriptionEngine: SidecarTranscriptionEngine
    @EnvironmentObject private var firstRunSetupController: FirstRunSetupController

    @State private var showPermissionDetails = false
    @State private var copiedEntryID: UUID?

    private var status: MenuBarStatus {
        MenuBarStatusModel.derive(
            missingPermissions: PermissionKind.allCases.filter {
                !permissionController.status(for: $0).isGranted
            },
            setupRequired: !settings.isSetupComplete(for: settings.selectedModel),
            engineState: transcriptionEngine.engineState,
            engineErrorReason: transcriptionEngine.lastErrorReason,
            notchActive: notchManager.state != .collapsed,
            monitoringEnabled: dictationSession.hotkeyMonitoringEnabled
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let banner = status.banner {
                healthBanner(banner)
            }
            hintRow
            Divider()
            quickControls
            Divider()
            recentSection
            Divider()
            footer
        }
        .frame(width: 300)
        .onAppear {
            audioCaptureManager.selectedInputDeviceID = settings.selectedMicrophoneID
            audioCaptureManager.refreshInputDevices()
            permissionController.refresh()
            firstRunSetupController.evaluate()
        }
    }

    // MARK: – Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarGlyph.image(for: status.glyph))
            Text("Magic Voice").font(.headline)
            Spacer()
            Text(status.statusWord)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func healthBanner(_ banner: MenuBarStatus.Banner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch banner {
            case .permissions(let missing):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(missing.count == 1
                         ? "\(missing[0].displayName) permission needed"
                         : "\(missing.count) permissions needed")
                        .font(.callout)
                    Spacer()
                    Button("Open…") {
                        if let first = missing.first {
                            permissionController.openSettings(for: first)
                        }
                    }
                    .controlSize(.small)
                }
                DisclosureGroup("Details", isExpanded: $showPermissionDetails) {
                    PermissionsView()
                        .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            case .engine(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout)
                        .lineLimit(3)
                    Spacer()
                    Button("Retry") {
                        if settings.isSetupComplete(for: settings.selectedModel) {
                            transcriptionEngine.restartEngine(
                                model: settings.selectedModel,
                                language: settings.language
                            )
                        } else {
                            firstRunSetupController.retry()
                        }
                    }
                    .controlSize(.small)
                }

            case .setup(let message):
                HStack(alignment: .center, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message)
                            .font(.callout)
                        Text("This can take a few minutes the first time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var hintRow: some View {
        HStack(spacing: 6) {
            Text("Hold")
            Text(settings.activationKey.displayName)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.tertiary, lineWidth: 0.5))
            Text("to dictate · double-tap to toggle")
            Spacer()
            Button(dictationSession.hotkeyMonitoringEnabled ? "Pause" : "Resume") {
                dictationSession.toggleHotkeyMonitoring()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            pickerRow(title: "Microphone", value: Binding(
                get: { settings.selectedMicrophoneID },
                set: {
                    settings.selectedMicrophoneID = $0
                    audioCaptureManager.selectedInputDeviceID = $0
                }
            )) {
                ForEach(audioCaptureManager.availableInputDevices) { device in
                    Text(device.isAuto
                         ? audioCaptureManager.displayName(forInputDeviceID: device.id)
                         : device.name)
                        .tag(device.id)
                }
            }

            pickerRow(title: "Language", value: $settings.language) {
                Text("Auto").tag("auto")
                Text("English").tag("en")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
            }

            pickerRow(title: "Shortcut", value: $settings.activationKey) {
                ForEach(ActivationKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Recent", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !settings.history.isEmpty {
                    Button("Clear") { settings.clearHistory() }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.history.isEmpty {
                Text("Nothing dictated yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(settings.history.prefix(3)) { entry in
                    recentCard(entry)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func recentCard(_ entry: TranscriptionEntry) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            copiedEntryID = entry.id
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if copiedEntryID == entry.id { copiedEntryID = nil }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                HStack {
                    Text(entry.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: copiedEntryID == entry.id ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copiedEntryID == entry.id ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: – Helpers

    private func pickerRow<Value: Hashable, Content: View>(
        title: String,
        value: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: value) { content() }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 170)
        }
    }
}

#Preview {
    let settings = SettingsStore()
    let notchManager = NotchWindowManager()
    let permissionController = PermissionController()
    let audioCaptureManager = AudioCaptureManager(permissionController: permissionController)
    let textInjector = TextInjector(permissionController: permissionController)
    let transcriptionEngine = SidecarTranscriptionEngine()
    let firstRunSetupController = FirstRunSetupController(
        settings: settings,
        permissionController: permissionController,
        engine: transcriptionEngine
    )

    MenuBarView()
        .environmentObject(settings)
        .environmentObject(notchManager)
        .environmentObject(permissionController)
        .environmentObject(audioCaptureManager)
        .environmentObject(transcriptionEngine)
        .environmentObject(firstRunSetupController)
        .environmentObject(DictationSession(
            settings: settings,
            notchManager: notchManager,
            permissionController: permissionController,
            audioCaptureManager: audioCaptureManager,
            textInjector: textInjector,
            transcriptionEngine: transcriptionEngine
        ))
}
