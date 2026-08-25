#if os(macOS)
import SwiftUI

struct MacAdvancedSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appCoordinator: AppDataCoordinator

    @State private var showingTroubleshootingWarning = false
    @State private var showingDataMigration = false
    @State private var showingAcknowledgements = false
    @State private var isPreparingLogs = false
    @State private var logExportError: String?

    var body: some View {
        MacSettingsPaneScroll(
            title: "Advanced",
            subtitle: "Open background jobs, diagnostics, database tools, and app information."
        ) {
            MacSettingsCard(title: "Background Processing", systemImage: "gearshape.2", tint: .blue) {
                Text(
                    "Monitor transcription and summarization jobs without changing their state when this window closes."
                )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    openWindow(id: NativeWindowID.backgroundProcessing)
                } label: {
                    Label("Open Background Processing", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
            }

            MacSettingsCard(title: "Diagnostics", systemImage: "stethoscope", tint: .orange) {
                Button {
                    exportDiagnosticLogs()
                } label: {
                    HStack(spacing: 12) {
                        Label("Export Diagnostic Logs", systemImage: "envelope")
                        Spacer()
                        if isPreparingLogs {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isPreparingLogs)
                .accessibilityLabel(isPreparingLogs ? "Preparing Diagnostic Logs" : "Export Diagnostic Logs")
                .accessibilityValue(isPreparingLogs ? "In progress" : "Ready")

                if let logExportError {
                    Text("Error: \(logExportError)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            MacSettingsCard(title: "Database Tools", systemImage: "externaldrive.badge.gearshape", tint: .red) {
                Text(
                    "These tools can delete or repair local data. Use them only when troubleshooting with a "
                        + "backup available."
                )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Database Tools", role: .destructive) {
                    showingTroubleshootingWarning = true
                }
                .buttonStyle(.bordered)
            }

            MacSettingsCard(title: "About", systemImage: "info.circle", tint: .indigo) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BisonNotes AI")
                            .font(.subheadline.weight(.semibold))
                        Text("Native macOS settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text(appVersion)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Version \(appVersion)")
                }

                Button {
                    showingAcknowledgements = true
                } label: {
                    Label("Acknowledgements", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .alert("Warning", isPresented: $showingTroubleshootingWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) {
                showingDataMigration = true
            }
        } message: {
            Text("These tools can delete data. Use with caution and keep a backup before proceeding.")
        }
        .sheet(isPresented: $showingDataMigration) {
            DataMigrationView()
                .environmentObject(appCoordinator)
                .nativeMacPresentationContext(.modalSheet)
                .nativeMacModalSizing(width: 800, height: 700)
                .onExitCommand {
                    showingDataMigration = false
                }
        }
        .sheet(isPresented: $showingAcknowledgements) {
            MacAcknowledgementsSheet()
                .nativeMacPresentationContext(.modalSheet)
                .nativeMacModalSizing(width: 760, height: 700)
        }
    }

    private var appVersion: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private func exportDiagnosticLogs() {
        logExportError = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            isPreparingLogs = true
        }

        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try await LogExporter.exportLogs()
                }.value

                await MainActor.run {
                    LogEmailPresenter.shared.presentLogEmail(
                        logFileURL: url,
                        onPresented: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPreparingLogs = false
                            }
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPreparingLogs = false
                            }
                        }
                    )
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPreparingLogs = false
                    }
                    logExportError = error.localizedDescription
                }
            }
        }
    }
}

private struct MacAcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AcknowledgementsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .onExitCommand {
            dismiss()
        }
    }
}
#endif
