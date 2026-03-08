//
//  PermissionsView.swift
//  magic-voice
//
//  Magic Voice — live TCC status rows for required macOS permissions.
//

import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var permissionController: PermissionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Permissions")
                Spacer()
                if permissionController.isPolling {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }
            }

            ForEach(PermissionKind.allCases) { kind in
                permissionRow(for: kind)
            }
        }
        .padding(.horizontal, 12)
        .onAppear {
            permissionController.refresh()
        }
    }

    private func permissionRow(for kind: PermissionKind) -> some View {
        let status = permissionController.status(for: kind)

        return HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.body)
                Text(kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(actionTitle(for: status)) {
                performAction(for: kind, status: status)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(status == .granted)
            .help(status.title)
        }
    }

    private func performAction(for kind: PermissionKind, status: PermissionStatus) {
        switch status {
        case .granted:
            break
        case .needsAccess:
            permissionController.request(kind)
        case .denied, .restricted:
            permissionController.openSettings(for: kind)
            permissionController.startPolling()
        case .unknown:
            permissionController.refresh()
        }
    }

    private func actionTitle(for status: PermissionStatus) -> String {
        switch status {
        case .granted:
            return "Granted"
        case .needsAccess:
            return "Allow"
        case .denied, .restricted:
            return "Settings"
        case .unknown:
            return "Recheck"
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

#Preview {
    PermissionsView()
        .environmentObject(PermissionController())
        .frame(width: 340)
        .padding()
}
