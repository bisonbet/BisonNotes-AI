import SwiftUI

struct DiagnosticConsentSettingsView: View {
    @AppStorage(DiagnosticConsentStore.enabledKey) private var isEnabled = false
    @State private var showingDisclosure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Automatically send technical crash reports",
                isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in
                        if newValue {
                            showingDisclosure = true
                        } else {
                            isEnabled = false
                            updateConsent(enabled: false)
                        }
                    }
                )
            )
            .accessibilityIdentifier("automaticDiagnosticReportsToggle")

            Text(
                "Optional reports include app/build, OS, platform, hardware model identifier, "
                    + "operation categories, bucketed measurements, and reviewed crash stack "
                    + "UUIDs/offsets. They never include audio, transcripts, summaries, recording "
                    + "names or IDs, paths, URLs, prompts, credentials, or diagnostic logs."
            )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Reports are sent to the BisonNotes diagnostics receiver only when one is configured, "
                    + "and are retained there for up to 14 days. Turning this off deletes local "
                    + "automatic events and queued reports; already-received reports cannot be recalled."
            )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Automatic Technical Crash Reports", isPresented: $showingDisclosure) {
            Button("Cancel", role: .cancel) { }
            Button("Enable") {
                isEnabled = true
                updateConsent(enabled: true)
            }
        } message: {
            Text(
                "BisonNotes will collect only the bounded technical fields described here to improve app reliability. "
                    + "This is separate from the detailed diagnostic export, which is never sent automatically."
            )
        }
    }

    private func updateConsent(enabled: Bool) {
        Task {
            await DiagnosticReportingService.shared.setConsent(enabled: enabled)
        }
    }
}
