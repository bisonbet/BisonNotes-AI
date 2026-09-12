import SwiftUI

/// Reusable blocking migration screen. Startup wiring should present this
/// view only after it has a real source snapshot and destination operation;
/// the view itself never opens a store or touches user data.
struct SQLiteMigrationProgressView: View {
    @ObservedObject var viewModel: SQLiteMigrationProgressViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 42))
                .foregroundStyle(.tint)

            Text("Updating your library")
                .font(.title2.weight(.semibold))

            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)

            progressContent
            actionContent
        }
        .padding(32)
        .frame(minWidth: 420, maxWidth: 560)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SQLite library migration")
    }

    private var description: String {
        switch viewModel.state {
        case .idle:
            return "BisonNotes will move your library metadata to its new local database. Audio files are handled separately in the background."
        case .running:
            return "Keep the app open while library metadata is being checked and copied. You can pause safely at any time."
        case .paused:
            return "The migration is paused. Your existing library remains available until the migration is verified."
        case .failed:
            return viewModel.failureMessage ?? SQLiteMigrationPresentationModel.genericFailureMessage
        case .completed:
            return "Your library metadata has been verified. Audio reconciliation can continue in the background."
        }
    }

    @ViewBuilder
    private var progressContent: some View {
        if let progress = viewModel.progress {
            ProgressView(value: progress.fractionCompleted)
                .accessibilityValue(Text(progressValue(for: progress)))

            Text(progressValue(for: progress))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if viewModel.isRunning {
            ProgressView()
                .controlSize(.small)
            Text("Preparing…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        switch viewModel.state {
        case .idle:
            Button("Start Migration") {
                viewModel.start()
            }
            .buttonStyle(.borderedProminent)
        case .running:
            Button("Pause Safely") {
                viewModel.cancel()
            }
            .buttonStyle(.bordered)
        case .paused, .failed:
            Button(viewModel.state == .paused ? "Continue" : "Try Again") {
                viewModel.retry()
            }
            .buttonStyle(.borderedProminent)
        case .completed:
            Label("Migration verified", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func progressValue(for progress: SQLiteMigrationProgress) -> String {
        switch progress.phase {
        case .applyingSettings:
            return "Settings: \(progress.settingsCompleted) of \(progress.settingsTotal)"
        case .verifying:
            return "Verifying metadata"
        case .completed:
            return "Migration verified"
        case .paused:
            return "Paused at \(progress.metadataCompleted) of \(progress.metadataTotal) metadata rows"
        case .failed:
            return "Migration needs attention"
        default:
            return "Metadata: \(progress.metadataCompleted) of \(progress.metadataTotal)"
        }
    }
}
