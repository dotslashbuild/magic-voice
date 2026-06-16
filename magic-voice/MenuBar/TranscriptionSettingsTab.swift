//
//  TranscriptionSettingsTab.swift
//  magic-voice
//
//  Magic Voice — Settings window: model choice and engine status/restart.
//

import SwiftUI

struct TranscriptionSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: SidecarTranscriptionEngine
    @EnvironmentObject private var firstRunSetupController: FirstRunSetupController

    var body: some View {
        Form {
            Section("Model") {
                ForEach(STTModel.allCases) { model in
                    modelRow(model)
                }
            }

            Section("Engine") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(engine.engineState == .ready || engine.engineState == .transcribing
                              ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(engine.engineState.rawValue)
                    Spacer()
                    Button("Restart") {
                        engine.restartEngine(model: settings.selectedModel, language: settings.language)
                    }
                    .disabled(engine.engineState == .loadingModel)
                    Button("Download Model") {
                        firstRunSetupController.downloadSelectedModel()
                    }
                    .disabled(engine.engineState == .loadingModel)
                }
                if let reason = engine.lastErrorReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }

    private func modelRow(_ model: STTModel) -> some View {
        Button {
            settings.selectedModel = model
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: settings.selectedModel == model ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(settings.selectedModel == model ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                    Text(model.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
