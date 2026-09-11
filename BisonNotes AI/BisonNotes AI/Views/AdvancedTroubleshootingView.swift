//
//  AdvancedTroubleshootingView.swift
//  BisonNotes AI
//
//  Read-only local diagnostics, reviewed audio cleanup, and iCloud maintenance.
//

import SwiftUI

// This screen deliberately keeps the three maintenance surfaces together so
// their mutual safety and dismissal behavior remain visible during review.
// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
struct AdvancedTroubleshootingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recorderVM: AudioRecorderViewModel
    @EnvironmentObject private var appCoordinator: AppDataCoordinator
    @EnvironmentObject private var fileImportManager: FileImportManager
    @EnvironmentObject private var transcriptImportManager: TranscriptImportManager
    @ObservedObject private var iCloudManager = iCloudStorageManager.shared

    @State private var operation: TroubleshootingOperation?
    @State private var operationTask: Task<Void, Never>?
    @State private var localDataReport: LocalDataReport?
    @State private var localDataReportError: String?
    @State private var audioScanResult: UnreferencedAudioScanResult?
    @State private var audioScanError: String?
    @State private var selectedAudioPaths: Set<String> = []
    @State private var audioCleanupResult: AudioCleanupResult?
    @State private var showingAudioDeleteConfirmation = false

    @AppStorage("iCloudBackupIncludeAudioFiles") private var iCloudBackupIncludeAudioFiles = false
    @AppStorage("iCloudBackupIncludeSettings") private var iCloudBackupIncludeSettings = true
    @AppStorage("iCloudBackupIncludeSensitiveSettings") private var iCloudBackupIncludeSensitiveSettings = false
    @State private var showingCloudEraseConfirmation = false
    @State private var cloudEraseConfirmationText = ""
    @State private var isCloudMaintenanceRunning = false
    @State private var showingCloudMaintenanceResult = false
    @State private var cloudMaintenanceResult: CloudMaintenanceResult?

    private enum TroubleshootingOperation: Equatable {
        case localReport
        case audioScan
        case audioDelete

        var statusText: String {
            switch self {
            case .localReport:
                return "Reading local data…"
            case .audioScan:
                return "Scanning Documents…"
            case .audioDelete:
                return "Rechecking selected audio…"
            }
        }
    }

    private struct CloudMaintenanceResult {
        let title: String
        let message: String
        let offersFreshUpload: Bool
    }

    private static let cloudEraseConfirmationPhrase = "ERASE"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    localDataReportSection
                    unreferencedAudioSection
                    iCloudMaintenanceSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .background(Color.secondary.opacity(0.06))
            .navigationTitle("Advanced Troubleshooting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
#if os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("bisonnotes.advanced-troubleshooting.cancel")
                }
#else
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
#endif
            }
            .alert("Delete Selected Audio?", isPresented: $showingAudioDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Selected Audio", role: .destructive) {
                    startAudioDeletion()
                }
            } message: {
                Text(
                    "This removes only the \(selectedAudioCandidates.count) reviewed audio "
                        + "file\(selectedAudioCandidates.count == 1 ? "" : "s") "
                        + "(\(formatFileSize(selectedAudioBytes))) from this device. "
                        + "Local database rows and iCloud data are not changed."
                )
            }
            .alert("Erase All iCloud Data", isPresented: $showingCloudEraseConfirmation) {
                TextField("Type \(Self.cloudEraseConfirmationPhrase) to confirm", text: $cloudEraseConfirmationText)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {
                    cloudEraseConfirmationText = ""
                }
                Button("Erase iCloud Data", role: .destructive) {
                    guard isCloudEraseConfirmed else {
                        cloudEraseConfirmationText = ""
                        cloudMaintenanceResult = CloudMaintenanceResult(
                            title: "Nothing Erased",
                            message: """
                            The confirmation did not match. Type \(Self.cloudEraseConfirmationPhrase) exactly to erase
                            your iCloud data.
                            """,
                            offersFreshUpload: false
                        )
                        showingCloudMaintenanceResult = true
                        return
                    }
                    cloudEraseConfirmationText = ""
                    startCloudErase()
                }
                .disabled(!isCloudEraseConfirmed)
            } message: {
                Text("""
                This permanently deletes everything BisonNotes AI stores in your iCloud account:

                • Backed-up recordings, transcripts, and summaries
                • Any audio files uploaded to iCloud
                • Backed-up app settings and sync bookkeeping records

                Nothing on this device is deleted. Your local recordings, transcripts,
                and summaries stay exactly as they are, and you can upload a fresh copy
                after the erase finishes.

                Other devices keep their own local data, but they will find nothing in iCloud
                until a fresh copy is uploaded.

                This cannot be undone and may take several minutes. Type
                \(Self.cloudEraseConfirmationPhrase) below to confirm.
                """)
            }
            .alert(
                cloudMaintenanceResult?.title ?? "",
                isPresented: $showingCloudMaintenanceResult,
                presenting: cloudMaintenanceResult
            ) { result in
                if result.offersFreshUpload {
                    Button("Upload Fresh Copy") {
                        startFreshCloudUpload()
                    }
                    Button("Not Now", role: .cancel) { }
                } else {
                    Button("OK", role: .cancel) { }
                }
            } message: { result in
                Text(result.message)
            }
        }
        .nativeMacPresentationContext(.modalSheet)
#if os(macOS)
        .onExitCommand {
            if operation == nil { dismiss() } else { cancelOperation() }
        }
#endif
        .onDisappear {
            operationTask?.cancel()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Advanced Troubleshooting")
                .font(.title2.weight(.bold))

            Text(
                "Inspect local data without changing it, review unreferenced audio before removing it, "
                    + "or manage the iCloud backup copy. These actions do not verify cloud completeness."
            )
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var localDataReportSection: some View {
        troubleshootingCard(title: "Local Data Report", systemImage: "doc.text.magnifyingglass", tint: .blue) {
            Text("""
            Read-only inspection of local Core Data rows, relationships, identities, and expected local audio.
            No rows, files, or cloud records are changed.
            """)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actionRow(
                title: localDataReport == nil ? "Run Local Data Report" : "Run Report Again",
                systemImage: "arrow.clockwise",
                isRunning: operation == .localReport,
                action: startLocalDataReport
            )
            .accessibilityIdentifier("bisonnotes.advanced-troubleshooting.run-report")
            .disabled(operation != nil)

            if operation == .localReport {
                operationProgress
            }

            if let localDataReportError {
                errorMessage(localDataReportError)
            }

            if let localDataReport {
                localDataReportSummary(localDataReport)
            }
        }
    }

    private var unreferencedAudioSection: some View {
        troubleshootingCard(title: "Review Unreferenced Audio", systemImage: "waveform.badge.xmark", tint: .orange) {
            Text("""
            Scan only covers non-hidden regular m4a, wav, mp3, and aac files directly inside the app's Documents folder.
            Archived, referenced, imported, and active files are protected.
            """)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actionRow(
                title: audioScanResult == nil ? "Scan for Unreferenced Audio" : "Scan Again",
                systemImage: "magnifyingglass",
                isRunning: operation == .audioScan,
                action: startAudioScan
            )
            .accessibilityIdentifier("bisonnotes.advanced-troubleshooting.scan-audio")
            .disabled(operation != nil)

            if operation == .audioScan {
                operationProgress
            }

            if let audioScanError {
                errorMessage(audioScanError)
            }

            if let audioScanResult {
                audioScanSummary(audioScanResult)
            }

            if operation == .audioDelete {
                operationProgress
            }

            if let audioCleanupResult {
                audioCleanupSummary(audioCleanupResult)
            }
        }
    }

    private var iCloudMaintenanceSection: some View {
        troubleshootingCard(title: "Erase All iCloud Data", systemImage: "icloud.slash", tint: .red) {
            Text("""
            Permanently erase the BisonNotes backup copy in iCloud while leaving this device unchanged.
            This is independent of the local report and audio review.
            """)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                cloudEraseConfirmationText = ""
                showingCloudEraseConfirmation = true
            } label: {
                Label(
                    isCloudMaintenanceRunning ? "Working in iCloud…" : "Erase All iCloud Data",
                    systemImage: "icloud.slash"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isCloudEraseDisabled)
            .accessibilityIdentifier("bisonnotes.advanced-troubleshooting.erase-icloud")

            Text(
                iCloudManager.isEnabled
                    ? """
                    The typed confirmation appears here at the irreversible action. Local recordings, transcripts,
                    and summaries are not touched.
                    """
                    : "Turn on iCloud Sync in Settings to manage iCloud data."
            )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func troubleshootingCard<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundColor(tint)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func actionRow(
        title: String,
        systemImage: String,
        isRunning: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
    }

    private var operationProgress: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(operation?.statusText ?? "Working…")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Cancel") { cancelOperation() }
                .font(.caption)
        }
        .padding(.vertical, 2)
    }

    // Keep the report summary together so all classifications and issues are
    // visible in the same read-only result card.
    // swiftlint:disable function_body_length
    @ViewBuilder
    private func localDataReportSummary(_ report: LocalDataReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "Inspection: \(report.status.displayName)",
                    systemImage: report.status == .complete ? "checkmark.circle" : "exclamationmark.triangle"
                )
                    .foregroundColor(report.status == .complete ? .green : .orange)
                Spacer()
                Text(report.generatedAt, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(
                "\(report.recordingCount) recording rows • "
                    + "\(report.transcriptCount) transcript rows • "
                    + "\(report.summaryCount) summary rows • "
                    + "\(report.processingJobCount) processing jobs"
            )
                .font(.caption)
                .foregroundColor(.secondary)

            let populatedKinds = LocalDataRecordKind.allCases.filter { report.count(for: $0) > 0 }
            if !populatedKinds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Record classifications")
                        .font(.caption.weight(.semibold))
                    ForEach(populatedKinds, id: \.self) { kind in
                        Text("• \(kind.displayName): \(report.count(for: kind))")
                            .font(.caption)
                    }
                }
            }

            if report.issues.isEmpty && report.status == .complete {
                Label("No local data issues found.", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.green)
            } else {
                Text("\(report.issueCount) issue\(report.issueCount == 1 ? "" : "s") reported")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.orange)
                ForEach(report.issues) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.category.displayName)
                            .font(.caption.weight(.semibold))
                        Text(issue.message)
                            .font(.caption)
                    }
                    .padding(.leading, 8)
                }
            }

            // Two recordings that share a display name produce byte-identical
            // warnings, so the position is the identity here — using the text
            // would silently collapse them into one row.
            ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.top, 4)
    }
    // swiftlint:enable function_body_length

    // The candidate list intentionally stays in one review surface so the
    // selection and confirmation controls cannot be separated from the scan.
    // swiftlint:disable function_body_length
    @ViewBuilder
    private func audioScanSummary(_ result: UnreferencedAudioScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.directoryDescription)
                .font(.caption)
                .foregroundColor(.secondary)

            if result.candidates.isEmpty {
                Label("No eligible unreferenced audio files found.", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.green)
            } else {
                Text("Select files to review and delete. Nothing is selected automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(result.candidates) { candidate in
                    Toggle(isOn: selectionBinding(for: candidate.path)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.fileName)
                                .font(.subheadline)
                            Text(formatFileSize(candidate.byteCount))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityIdentifier("bisonnotes.advanced-troubleshooting.audio.\(candidate.id)")
                }

                if let reason = result.deletionUnavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if result.protectedFileCount > 0 {
                    Text(
                        "\(result.protectedFileCount) file\(result.protectedFileCount == 1 ? "" : "s") "
                            + "was protected because it is referenced or owned by active work."
                    )
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button {
                    showingAudioDeleteConfirmation = true
                } label: {
                    Label("Delete Selected Audio", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(
                    operation != nil
                        || selectedAudioCandidates.isEmpty
                        || result.deletionUnavailableReason != nil
                )
                .accessibilityIdentifier("bisonnotes.advanced-troubleshooting.delete-audio")
            }
        }
        .padding(.top, 4)
    }
    // swiftlint:enable function_body_length

    @ViewBuilder
    private func audioCleanupSummary(_ result: AudioCleanupResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if result.cancelled {
                Text("Audio review was cancelled. No additional files were processed.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if result.deletedAudioCount > 0 || result.deletedSidecarCount > 0 {
                let audioDescription = "Deleted \(result.deletedAudioCount) "
                    + "audio file\(result.deletedAudioCount == 1 ? "" : "s") "
                    + "(\(formatFileSize(result.deletedAudioBytes)))"
                let sidecarDescription = "\(result.deletedSidecarCount) "
                    + "permitted sidecar\(result.deletedSidecarCount == 1 ? "" : "s") "
                    + "(\(formatFileSize(result.deletedSidecarBytes)))"
                Text("\(audioDescription) and \(sidecarDescription).")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.green)
            } else if result.failures.isEmpty && !result.cancelled {
                Text("No selected files were deleted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // A `.sidecarShared` entry describes a file that WAS deleted — only
            // its sidecars were kept. Rendering it as "Skipped" alongside the
            // deleted count would list the same name as both deleted and
            // skipped, leaving the user unable to tell what happened to it.
            let retainedSidecars = result.skipped.filter { $0.reason == .sidecarShared }
            let skippedCandidates = result.skipped.filter { $0.reason != .sidecarShared }

            ForEach(skippedCandidates) { item in
                Text("Skipped \(URL(fileURLWithPath: item.path).lastPathComponent): \(item.detail)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            ForEach(retainedSidecars) { item in
                Text(
                    "Removed \(URL(fileURLWithPath: item.path).lastPathComponent), but kept its "
                        + "sidecars: \(item.detail)"
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(result.failures) { item in
                Text("Could not remove \(URL(fileURLWithPath: item.path).lastPathComponent): \(item.message)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.top, 4)
    }

    private func errorMessage(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundColor(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isCloudEraseConfirmed: Bool {
        cloudEraseConfirmationText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() == Self.cloudEraseConfirmationPhrase
    }

    private var isCloudEraseDisabled: Bool {
        isCloudMaintenanceRunning || !iCloudManager.isEnabled
    }

    private var selectedAudioCandidates: [UnreferencedAudioCandidate] {
        audioScanResult?.candidates.filter { selectedAudioPaths.contains($0.path) } ?? []
    }

    private var selectedAudioBytes: Int64 {
        selectedAudioCandidates.reduce(0) { $0 + $1.byteCount }
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedAudioPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedAudioPaths.insert(path)
                } else {
                    selectedAudioPaths.remove(path)
                }
            }
        )
    }

    private func startLocalDataReport() {
        guard operation == nil else { return }
        localDataReport = nil
        localDataReportError = nil
        operation = .localReport
        operationTask = Task { @MainActor in
            defer {
                operation = nil
                operationTask = nil
            }
            do {
                let report = try await AdvancedTroubleshootingService(
                    coreDataManager: appCoordinator.coreDataManager
                ).makeLocalDataReport()
                guard !Task.isCancelled else { return }
                localDataReport = report
            } catch is CancellationError {
                // Cancellation leaves the previous screen state intact.
            } catch {
                guard !Task.isCancelled else { return }
                localDataReportError = error.localizedDescription
            }
        }
    }

    private func startAudioScan() {
        guard operation == nil else { return }
        audioScanResult = nil
        audioScanError = nil
        audioCleanupResult = nil
        selectedAudioPaths = []
        operation = .audioScan
        let activity = audioActivitySnapshot
        operationTask = Task { @MainActor in
            defer {
                operation = nil
                operationTask = nil
            }
            do {
                let result = try await AdvancedTroubleshootingService(
                    coreDataManager: appCoordinator.coreDataManager
                ).scanUnreferencedAudio(activity: activity)
                guard !Task.isCancelled else { return }
                audioScanResult = result
            } catch is CancellationError {
                // Cancellation leaves the previous scan state cleared.
            } catch {
                guard !Task.isCancelled else { return }
                audioScanError = error.localizedDescription
            }
        }
    }

    private func startAudioDeletion() {
        guard operation == nil, let audioScanResult else { return }
        audioScanError = nil
        audioCleanupResult = nil
        operation = .audioDelete
        let candidates = audioScanResult.candidates
        let selectedPaths = selectedAudioPaths
        operationTask = Task { @MainActor in
            defer {
                operation = nil
                operationTask = nil
            }
            do {
                let result = try await AdvancedTroubleshootingService(
                    coreDataManager: appCoordinator.coreDataManager
                ).deleteSelectedAudio(
                    candidates: candidates,
                    selectedIDs: selectedPaths,
                    activityProvider: { audioActivitySnapshot }
                )
                // A cancelled run still reports the files it had already
                // deleted, so the result is applied either way: dropping it
                // would leave removed files sitting in the reviewed list with
                // no record that anything happened.
                audioCleanupResult = result
                selectedAudioPaths.subtract(result.deletedPaths)
                if !result.deletedPaths.isEmpty {
                    self.audioScanResult = UnreferencedAudioScanResult(
                        generatedAt: audioScanResult.generatedAt,
                        directoryDescription: audioScanResult.directoryDescription,
                        candidates: audioScanResult.candidates.filter { !result.deletedPaths.contains($0.path) },
                        protectedFileCount: audioScanResult.protectedFileCount,
                        deletionUnavailableReason: audioScanResult.deletionUnavailableReason
                    )
                }
            } catch is CancellationError {
                // Cancellation leaves the reviewed list intact.
            } catch {
                guard !Task.isCancelled else { return }
                audioScanError = error.localizedDescription
            }
        }
    }

    /// Only asks the running work to stop. Clearing `operation` here would
    /// reopen the guard in `startAudioDeletion` while the previous loop was
    /// still deleting, letting two runs interleave over the same files; the
    /// task's own `defer` clears it once it has actually finished.
    private func cancelOperation() {
        operationTask?.cancel()
    }

    private func startCloudErase() {
        guard !isCloudEraseDisabled else { return }
        isCloudMaintenanceRunning = true
        Task { @MainActor in
            defer { isCloudMaintenanceRunning = false }
            do {
                let result = try await iCloudManager.eraseAlliCloudData()
                let recordText = "\(result.recordsDeleted) record\(result.recordsDeleted == 1 ? "" : "s")"
                let zoneText = result.zonesDeleted > 0
                    ? " and \(result.zonesDeleted) record zone\(result.zonesDeleted == 1 ? "" : "s")"
                    : ""

                if result.failures.isEmpty {
                    cloudMaintenanceResult = CloudMaintenanceResult(
                        title: "iCloud Data Erased",
                        message: """
                        Deleted \(recordText)\(zoneText) from iCloud.

                        Nothing on this device changed — your recordings, transcripts, and
                        summaries are all still here.

                        Upload a fresh copy now to rebuild iCloud from this device, or do it later from Settings.
                        """,
                        offersFreshUpload: true
                    )
                } else {
                    cloudMaintenanceResult = CloudMaintenanceResult(
                        title: "Erase Incomplete",
                        message: """
                        Deleted \(recordText)\(zoneText), but \(result.failures.count) item
                        \(result.failures.count == 1 ? "" : "s") could not be removed:

                        \(result.failures.prefix(3).joined(separator: "\n"))

                        Nothing on this device changed. Run the erase again to retry the remaining items.
                        """,
                        offersFreshUpload: false
                    )
                }
            } catch {
                cloudMaintenanceResult = CloudMaintenanceResult(
                    title: "Erase Failed",
                    message: """
                    Could not erase iCloud data: \(error.localizedDescription)

                    Nothing on this device changed.
                    """,
                    offersFreshUpload: false
                )
            }
            showingCloudMaintenanceResult = true
        }
    }

    private func startFreshCloudUpload() {
        guard !isCloudMaintenanceRunning else { return }
        isCloudMaintenanceRunning = true
        Task { @MainActor in
            defer { isCloudMaintenanceRunning = false }
            let options = CloudBackupOptions(
                includeAudioFiles: iCloudBackupIncludeAudioFiles,
                includeSettings: iCloudBackupIncludeSettings,
                includeSensitiveSettings: iCloudBackupIncludeSettings && iCloudBackupIncludeSensitiveSettings
            )

            do {
                let result = try await iCloudManager.backupAllDataToiCloud(
                    appCoordinator: appCoordinator,
                    options: options
                )
                cloudMaintenanceResult = CloudMaintenanceResult(
                    title: "Fresh Copy Uploaded",
                    message: """
                    Uploaded \(result.recordingsBackedUp) recordings, \(result.transcriptsBackedUp) transcripts,
                    \(result.summariesBackedUp) summaries, and \(result.audioFilesBackedUp) audio files to iCloud.

                    Audio files and settings follow the backup options in Settings.
                    """,
                    offersFreshUpload: false
                )
            } catch {
                cloudMaintenanceResult = CloudMaintenanceResult(
                    title: "Upload Failed",
                    message: """
                    Could not upload a fresh copy: \(error.localizedDescription)

                    Your local data is unchanged. You can retry from Settings › iCloud.
                    """,
                    offersFreshUpload: false
                )
            }
            showingCloudMaintenanceResult = true
        }
    }

    private var audioActivitySnapshot: AdvancedTroubleshootingActivitySnapshot {
        var ownedPaths: Set<String> = []

        func addOwnedPath(_ url: URL?) {
            guard let url else { return }
            ownedPaths.insert(AdvancedTroubleshootingService.canonicalPath(for: url))
        }

        addOwnedPath(recorderVM.recordingURL)
        addOwnedPath(recorderVM.mainRecordingURL)
        recorderVM.recordingSegments.forEach { addOwnedPath($0) }
        recorderVM.recordingAttemptArtifacts.forEach { addOwnedPath($0.url) }
#if os(macOS)
        addOwnedPath(recorderVM.macScratchRecordingURL)
        recorderVM.macScratchSegmentURLs.forEach { addOwnedPath($0) }
        addOwnedPath(recorderVM.macSystemAudioURL)
#endif

        // Writers that create a file in Documents before saving its Core Data
        // row are invisible to the unreferenced test for that whole gap.
        let inFlightAudioPaths = ActiveAudioWorkRegistry.shared.inFlightPaths
        ownedPaths.formUnion(inFlightAudioPaths)

        let existingBackgroundManager = BackgroundProcessingManager.existingInstance
        let activeProcessingJobs = existingBackgroundManager?.activeJobs.filter { !$0.status.isTerminal }
            ?? []
        for job in activeProcessingJobs + (existingBackgroundManager?.currentJob.map { [$0] } ?? []) {
            addOwnedPath(job.recordingURL)
            addOwnedPath(job.audioSourceURL)
        }

        var recorderIsBusy = recorderVM.isRecording
            || recorderVM.isStartingRecording
            || recorderVM.recordingIntentActive
            || recorderVM.recordingBeingProcessed
            || recorderVM.recordingState != .idle
#if os(iOS)
        recorderIsBusy = recorderIsBusy || recorderVM.isFinalizingRecoverySegment
#endif
#if os(macOS)
        recorderIsBusy = recorderIsBusy || recorderVM.isFinalizingMacRecording
#endif
        let importIsBusy = fileImportManager.isImporting || transcriptImportManager.isImporting
        let restoreIsBusy = iCloudManager.operationCoordinator.runningIntent?.installsLocalAudio == true

        if importIsBusy {
            return AdvancedTroubleshootingActivitySnapshot(
                blockAllDeletion: true,
                reason: "An import is active. Finish the import before deleting audio.",
                ownedPaths: ownedPaths,
                kind: .importing
            )
        }
        if recorderIsBusy {
            return AdvancedTroubleshootingActivitySnapshot(
                blockAllDeletion: true,
                reason: "A recording or audio recovery operation is active. Finish it before deleting audio.",
                ownedPaths: ownedPaths,
                kind: .recording
            )
        }
        if restoreIsBusy {
            return AdvancedTroubleshootingActivitySnapshot(
                blockAllDeletion: true,
                reason: "An iCloud sync that can restore audio is active. Let it finish before deleting audio.",
                ownedPaths: ownedPaths,
                kind: .restore
            )
        }
        if existingBackgroundManager?.currentJob != nil || !activeProcessingJobs.isEmpty {
            return AdvancedTroubleshootingActivitySnapshot(
                blockAllDeletion: true,
                reason: "Background audio processing is active. Finish it before deleting audio.",
                ownedPaths: ownedPaths,
                kind: .processing
            )
        }
        // On macOS the combine sheet and this screen can be open at once, and a
        // combine writes its output long before it saves a row for it.
        if !inFlightAudioPaths.isEmpty {
            return AdvancedTroubleshootingActivitySnapshot(
                blockAllDeletion: true,
                reason: "Recordings are being combined. Finish that before deleting audio.",
                ownedPaths: ownedPaths,
                kind: .combining
            )
        }
        return AdvancedTroubleshootingActivitySnapshot(
            blockAllDeletion: false,
            reason: nil,
            ownedPaths: ownedPaths,
            kind: .idle
        )
    }

    private func formatFileSize(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

// swiftlint:enable file_length
