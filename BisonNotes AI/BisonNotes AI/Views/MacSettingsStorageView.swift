#if os(macOS)
import SwiftUI

struct MacStorageSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appCoordinator: AppDataCoordinator
    @ObservedObject private var iCloudManager = iCloudStorageManager.shared

    @AppStorage("iCloudBackupIncludeAudioFiles") private var iCloudBackupIncludeAudioFiles = false
    @AppStorage("iCloudBackupIncludeSettings") private var iCloudBackupIncludeSettings = true
    @AppStorage("iCloudBackupIncludeSensitiveSettings") private var iCloudBackupIncludeSensitiveSettings = false

    @State private var showingICloudComplianceNotice = false
    @State private var isRunningCloudBackupAction = false
    @State private var cloudBackupActionMessage = ""
    @State private var cloudBackupActionIsError = false

    var body: some View {
        MacSettingsPaneScroll(
            title: "Storage",
            subtitle: "Manage iCloud sync, recovery, and the space used by local recordings."
        ) {
            MacStorageICloudCard(
                iCloudManager: iCloudManager,
                includeAudioFiles: $iCloudBackupIncludeAudioFiles,
                includeSettings: $iCloudBackupIncludeSettings,
                includeSensitiveSettings: $iCloudBackupIncludeSensitiveSettings,
                isRunning: $isRunningCloudBackupAction,
                actionMessage: $cloudBackupActionMessage,
                actionIsError: $cloudBackupActionIsError,
                onToggleCloudSync: handleCloudSyncToggle,
                onBackup: { Task { await backupAllDataToiCloud() } },
                onRestore: { Task { await restoreAllDataFromiCloud() } },
                onReview: { openWindow(id: NativeWindowID.cloudReview) },
                onCheckForCloudData: checkForiCloudData
            )
            .accessibilityIdentifier(BisonNotesAccessibilityID.iCloudSection)

            MacStorageLocalStorageCard(storageText: totalRecordingsStorageString)
        }
        .alert("iCloud Sync Notice", isPresented: $showingICloudComplianceNotice) {
            Button("Cancel", role: .cancel) { }
            Button("Enable iCloud Sync") {
                iCloudManager.isEnabled = true
            }
        } message: {
            Text(
                "BisonNotes AI and uploads to iCloud are not HIPAA-compliant. When iCloud Sync is enabled, "
                    + "eligible recordings, transcripts, summaries, and selected settings may be uploaded to "
                    + "your private iCloud account. To exclude an item from BisonNotes iCloud sync and backup, "
                    + "mark it Keep on This Device from its recording row or audio player."
            )
        }
    }
}

private extension MacStorageSettingsPane {
    func handleCloudSyncToggle(_ enabled: Bool) {
        if enabled {
            showingICloudComplianceNotice = true
        } else {
            iCloudManager.isEnabled = false
        }
    }

    func backupAllDataToiCloud() async {
        await MainActor.run {
            isRunningCloudBackupAction = true
            cloudBackupActionMessage = ""
            cloudBackupActionIsError = false
        }

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

            if result.wasSkippedNoChanges {
                await MainActor.run {
                    cloudBackupActionMessage = "Backup skipped: no local changes since the last successful backup."
                    cloudBackupActionIsError = false
                    isRunningCloudBackupAction = false
                }
                return
            }

            let settingsText: String
            if result.settingsBackedUp {
                settingsText = result.includedSensitiveSettings ? "settings + sensitive settings" : "settings"
            } else {
                settingsText = "no settings"
            }

            await MainActor.run {
                let unchangedAudioText = iCloudBackupIncludeAudioFiles
                    ? ", \(result.audioFilesSkippedUnchanged) audio unchanged"
                    : ""
                cloudBackupActionMessage =
                    "Backup complete: \(result.recordingsBackedUp) recordings, "
                        + "\(result.transcriptsBackedUp) transcripts, "
                        + "\(result.summariesBackedUp) summaries, \(result.audioFilesBackedUp) audio uploaded"
                        + "\(unchangedAudioText), \(settingsText)."
                cloudBackupActionIsError = false
                isRunningCloudBackupAction = false
            }
        } catch {
            await MainActor.run {
                cloudBackupActionMessage = "Backup failed: \(error.localizedDescription)"
                cloudBackupActionIsError = true
                isRunningCloudBackupAction = false
            }
        }
    }

    func restoreAllDataFromiCloud() async {
        await MainActor.run {
            isRunningCloudBackupAction = true
            cloudBackupActionMessage = ""
            cloudBackupActionIsError = false
        }

        do {
            let result = try await iCloudManager.restoreAllDataFromiCloud(
                appCoordinator: appCoordinator,
                includeAudioFiles: iCloudBackupIncludeAudioFiles,
                restoreSettings: iCloudBackupIncludeSettings
            )
            appCoordinator.syncRecordingURLs()

            let settingsText: String
            if result.settingsRestored {
                settingsText = result.includedSensitiveSettings ? "settings + sensitive settings" : "settings"
            } else {
                settingsText = "no settings"
            }

            await MainActor.run {
                let reviewText = result.itemsHeldForReview > 0
                    ? ", \(result.itemsHeldForReview) held for review"
                    : ""
                cloudBackupActionMessage =
                    "Restore complete: \(result.recordingsRestored) recordings, "
                        + "\(result.transcriptsRestored) transcripts, \(result.summariesRestored) summaries, "
                        + "\(result.audioFilesRestored) audio files, "
                        + "\(settingsText)\(reviewText)."
                cloudBackupActionIsError = false
                isRunningCloudBackupAction = false
            }
        } catch {
            await MainActor.run {
                cloudBackupActionMessage = "Restore failed: \(error.localizedDescription)"
                cloudBackupActionIsError = true
                isRunningCloudBackupAction = false
            }
        }
    }

    func checkForiCloudData() {
        Task {
            do {
                let cloudSummaries = try await iCloudManager.fetchSummariesFromiCloud(forRecovery: true)
                let localSummaryIds = Set(appCoordinator.coreDataManager.getAllSummaries().compactMap(\.id))
                let cloudOnlySummaries = cloudSummaries.filter { !localSummaryIds.contains($0.id) }

                if !cloudOnlySummaries.isEmpty {
                    await MainActor.run { presentCloudDataFoundAlert(count: cloudOnlySummaries.count) }
                } else {
                    await MainActor.run {
                        PlatformAlert.present(
                            title: "No iCloud Data",
                            message: "No summaries were found in your iCloud account."
                        )
                    }
                }
            } catch {
                AppLog.shared.log(
                    "Failed to check for iCloud data: \(error)",
                    level: .error,
                    category: .general
                )
                await MainActor.run {
                    PlatformAlert.present(
                        title: "Check Failed",
                        message: "Could not check for iCloud data: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func presentCloudDataFoundAlert(count: Int) {
        PlatformAlert.present(
            title: "iCloud Data Found",
            message: "We found \(count) summaries in your iCloud that aren't on this device.",
            actions: [
                PlatformAlert.Action(title: "Cancel", isCancel: true),
                PlatformAlert.Action(title: "Download") {
                    Task {
                        do {
                            let downloadedCount = try await iCloudManager.downloadSummariesFromCloud(
                                appCoordinator: appCoordinator,
                                forRecovery: true
                            )
                            AppLog.shared.log(
                                "Downloaded \(downloadedCount) summaries from iCloud",
                                category: .general
                            )
                        } catch {
                            AppLog.shared.log(
                                "Failed to download summaries: \(error)",
                                level: .error,
                                category: .general
                            )
                        }
                    }
                }
            ]
        )
    }

    var totalRecordingsStorageString: String {
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()
        var totalSize: Int64 = 0

        for entry in recordingsWithData {
            if entry.recording.audioQuality == "imported" {
                continue
            }

            guard let url = appCoordinator.getAbsoluteURL(for: entry.recording),
                  FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int64 {
                totalSize += size
            }
        }

        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}
#endif
