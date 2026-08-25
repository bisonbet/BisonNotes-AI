#if os(macOS)
import SwiftUI

struct MacStorageICloudCard: View {
    @ObservedObject var iCloudManager: iCloudStorageManager

    @Binding var includeAudioFiles: Bool
    @Binding var includeSettings: Bool
    @Binding var includeSensitiveSettings: Bool
    @Binding var isRunning: Bool
    @Binding var actionMessage: String
    @Binding var actionIsError: Bool

    let onToggleCloudSync: (Bool) -> Void
    let onBackup: () -> Void
    let onRestore: () -> Void
    let onReview: () -> Void
    let onCheckForCloudData: () -> Void

    var body: some View {
        MacSettingsCard(title: "iCloud Sync", systemImage: "icloud", tint: .blue) {
            Toggle(
                "Enable iCloud Sync",
                isOn: Binding(
                    get: { iCloudManager.isEnabled },
                    set: { enabled in
                        onToggleCloudSync(enabled)
                    }
                )
            )
                .accessibilityValue(AccessibilitySupport.statusValue(isOn: iCloudManager.isEnabled))
                .accessibilityHint("Shows a privacy notice before enabling iCloud sync.")
                .accessibilityIdentifier(BisonNotesAccessibilityID.iCloudEnableToggle)

            if iCloudManager.isEnabled {
                enabledCloudContent
            } else {
                Button {
                    onCheckForCloudData()
                } label: {
                    Label("Check for iCloud Data", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }

            conflictContent

            if let error = iCloudManager.lastError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var enabledCloudContent: some View {
        Toggle("Include audio files in backup", isOn: $includeAudioFiles)
            .accessibilityValue(AccessibilitySupport.statusValue(isOn: includeAudioFiles))

        Toggle("Include app settings", isOn: $includeSettings)
            .accessibilityValue(AccessibilitySupport.statusValue(isOn: includeSettings))

        Toggle("Include sensitive settings", isOn: $includeSensitiveSettings)
            .accessibilityValue(AccessibilitySupport.statusValue(isOn: includeSensitiveSettings))
            .disabled(!includeSettings)

        Text(
            "API keys stay in Keychain and are never included in iCloud settings backups. Leave sensitive "
                + "settings off unless you explicitly want eligible future sensitive preferences copied to iCloud."
        )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if iCloudManager.isAutomaticReconcileRunning {
            MacSettingsInlineStatus(
                title: "Syncing with iCloud...",
                subtitle: "Applying eligible changes and cleanup across devices",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .blue,
                showsProgress: true
            )
        } else if let message = iCloudManager.lastMaintenanceMessage {
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 10) {
            Button(action: onBackup) {
                Label("Backup", systemImage: "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRunning)

            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRunning)
        }

        Button(action: onReview) {
            Label("Review iCloud Items", systemImage: "tray.full")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isRunning)
        .accessibilityIdentifier(BisonNotesAccessibilityID.iCloudReviewItemsButton)

        if isRunning {
            MacSettingsInlineStatus(
                title: "Working...",
                subtitle: nil,
                systemImage: "arrow.triangle.2.circlepath",
                tint: .secondary,
                showsProgress: true
            )
        }

        if !actionMessage.isEmpty {
            Text(actionMessage)
                .font(.caption)
                .foregroundColor(actionIsError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var conflictContent: some View {
        if !iCloudManager.pendingConflicts.isEmpty {
            ForEach(iCloudManager.pendingConflicts, id: \.summaryId) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.localSummary.recordingName)
                        .font(.caption.weight(.semibold))

                    Text("Modified on different devices")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack {
                        Button("Use Local") {
                            Task { try? await iCloudManager.resolveConflict(conflict, useLocal: true) }
                        }
                        .buttonStyle(.bordered)

                        Button("Use Cloud") {
                            Task { try? await iCloudManager.resolveConflict(conflict, useLocal: false) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
#endif
