//
//  TranscriptCleanupControls.swift
//  BisonNotes AI
//
//  Transcript Cleanup settings, shown on the Beta Features page once the
//  Transcript Cleanup beta is on.
//

import SwiftUI

struct TranscriptCleanupControls: View {
    @AppStorage(TranscriptCleanupSettings.Keys.enabled)
    private var transcriptCleanupEnabled: Bool = TranscriptCleanupSettings.defaultEnabled
    @StateObject private var transcriptCleanupModelManager = TranscriptCleanupModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Clean up transcripts automatically (English only)", isOn: $transcriptCleanupEnabled)
                .accessibilityValue(AccessibilitySupport.statusValue(isOn: transcriptCleanupEnabled))
                .accessibilityIdentifier(BisonNotesAccessibilityID.transcriptCleanupToggle)
                // An unsupported device must still be able to turn an inherited
                // "on" back off: a restore from a supported device would otherwise
                // leave the toggle on and disabled, so every queued transcription
                // snapshotted cleanup as enabled and warned about the platform.
                .disabled(!TranscriptCleanupSettings.availability.isAvailable && !transcriptCleanupEnabled)
                .onChange(of: transcriptCleanupEnabled) { _, enabled in
                    if enabled && !TranscriptCleanupSettings.availability.isAvailable {
                        transcriptCleanupEnabled = false
                    }
                }
                .onAppear {
                    if transcriptCleanupEnabled && !TranscriptCleanupSettings.availability.isAvailable {
                        transcriptCleanupEnabled = false
                    }
                }

            Text("Runs on this device after file transcription. Improves punctuation, removes fillers, and resolves spoken corrections. Original text and speaker labels are preserved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(TranscriptCleanupSettings.modelAttribution)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            if let reason = TranscriptCleanupSettings.availability.explanation {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                modelControls
            }

            Text("Automatic summaries continue to use the original transcript text. Imported text is cleaned only when you request it from the transcript editor.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        HStack(spacing: 10) {
            switch transcriptCleanupModelManager.state {
            case .downloading:
                ProgressView(value: transcriptCleanupModelManager.progress)
                    .frame(maxWidth: 180)
                Text("Downloading…")
                    .font(.caption)
                Button("Cancel") {
                    transcriptCleanupModelManager.cancelDownload()
                }
                .buttonStyle(.bordered)
            case .waitingForCacheMaintenance:
                ProgressView()
                    .controlSize(.small)
                Text(transcriptCleanupModelManager.statusDescription)
                    .font(.caption)
                if transcriptCleanupModelManager.isDownloadCancellable {
                    Button("Cancel") {
                        transcriptCleanupModelManager.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                }
            case .waitingForInference:
                ProgressView()
                    .controlSize(.small)
                Text(transcriptCleanupModelManager.statusDescription)
                    .font(.caption)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.green)
                Spacer()
                Button("Remove Download", role: .destructive) {
                    transcriptCleanupModelManager.deleteDownloadedModel()
                }
                .buttonStyle(.bordered)
            default:
                Text(transcriptCleanupModelManager.statusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Download S1-mini") {
                    transcriptCleanupModelManager.startDownload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            transcriptCleanupModelManager.refresh()
        }
    }
}
