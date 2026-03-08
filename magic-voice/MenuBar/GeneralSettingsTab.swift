//
//  GeneralSettingsTab.swift
//  magic-voice
//
//  Magic Voice — Settings window: launch, activation key, language.
//

import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)

            Picker("Activation key", selection: Binding(
                get: { settings.activationKey },
                set: { settings.activationKey = $0 }
            )) {
                ForEach(ActivationKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }

            Picker("Language", selection: $settings.language) {
                Text("Auto").tag("auto")
                Text("English").tag("en")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}
