//
//  UITestSupport.swift
//  BisonNotes AI
//

#if DEBUG
import AVFoundation
import CoreData
import Foundation

enum BisonNotesUITestSupport {
    static let uiTestingArgument = "--ui-testing"
    static let resetDataArgument = "--reset-test-data"
    static let seedSampleRecordingArgument = "--seed-sample-recording"
    static let disableCloudServicesArgument = "--disable-cloud-services"
    static let showFirstSetupArgument = "--show-first-setup"

    private static let preparedFlagKey = "BisonNotesUITestSupportPreparedThisLaunch"
    private static let sampleRecordingName = "UI Test Recording"
    private static let sampleFileName = "ui-test-recording.caf"

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestingArgument)
    }

    static func configureProcessDefaults() {
        guard isUITesting else { return }

        let defaults = UserDefaults.standard
        let shouldShowFirstSetup = ProcessInfo.processInfo.arguments.contains(showFirstSetupArgument)
        defaults.set(!shouldShowFirstSetup, forKey: "hasCompletedFirstSetup")
        defaults.set(!shouldShowFirstSetup, forKey: "hasCompletedInitialSetup")
        defaults.set(true, forKey: "hasAskedLocationPermission")
        defaults.set(TranscriptionEngine.fluidAudio.rawValue, forKey: "selectedTranscriptionEngine")
        defaults.set(AIEngineType.mlxSwift.rawValue, forKey: "SelectedAIEngine")
        defaults.set(false, forKey: "showAppleIntelligenceMigrationAlert")
        defaults.set(false, forKey: "showParakeetMigrationSettings")
        defaults.set(false, forKey: "showWhisperKitSwitchedToParakeet")
        defaults.set(false, forKey: "showWhisperKitRemovedAlert")

        if ProcessInfo.processInfo.arguments.contains(disableCloudServicesArgument) {
            defaults.set(false, forKey: "iCloudSyncEnabled")
            defaults.set(false, forKey: "shouldPerformFullSyncOnStartup")
            defaults.set("disabled", forKey: "autoSyncMode")
            defaults.set(false, forKey: "iCloudBackupIncludeAudioFiles")
            defaults.set(false, forKey: "iCloudBackupIncludeSensitiveSettings")
        }

        defaults.removeObject(forKey: preparedFlagKey)
    }

    @MainActor
    static func prepareLaunchDataIfNeeded(appCoordinator: AppDataCoordinator) {
        guard isUITesting else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: preparedFlagKey) else { return }

        if ProcessInfo.processInfo.arguments.contains(resetDataArgument) {
            resetPersistentData(in: appCoordinator.coreDataManager)
        }

        if ProcessInfo.processInfo.arguments.contains(seedSampleRecordingArgument) {
            seedSampleRecordingIfNeeded(appCoordinator: appCoordinator)
        }

        defaults.set(true, forKey: preparedFlagKey)
    }

    @MainActor
    private static func resetPersistentData(in coreDataManager: CoreDataManager) {
        let context = coreDataManager.contextForTesting
        let model = context.persistentStoreCoordinator?.managedObjectModel

        model?.entities.compactMap(\.name).forEach { entityName in
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            if let objects = try? context.fetch(request) {
                objects.forEach(context.delete)
            }
        }
        try? context.save()

        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let contents = try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
            for file in contents where file.lastPathComponent.hasPrefix("ui-test-") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    @MainActor
    private static func seedSampleRecordingIfNeeded(appCoordinator: AppDataCoordinator) {
        let existing = appCoordinator.coreDataManager.getAllRecordings()
            .contains { $0.recordingName == sampleRecordingName }
        guard !existing else { return }

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let audioURL = documentsURL.appendingPathComponent(sampleFileName)
        try? createSilentAudioFixture(at: audioURL)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        let recordingId = appCoordinator.addRecording(
            url: audioURL,
            name: sampleRecordingName,
            date: Date(timeIntervalSince1970: 1_772_000_000),
            fileSize: fileSize,
            duration: 2.0,
            quality: .whisperOptimized
        )

        let segments = [
            TranscriptSegment(
                speaker: "Speaker 1",
                text: "This is a deterministic transcript seeded for UI regression tests.",
                startTime: 0,
                endTime: 2
            )
        ]
        guard let transcriptId = appCoordinator.addTranscript(
            for: recordingId,
            segments: segments,
            engine: .fluidAudio,
            processingTime: 0.1,
            confidence: 0.99
        ) else {
            return
        }

        _ = appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "This seeded UI test summary is intentionally long enough to pass summary validation and prove the summary linkage survives launch.",
            tasks: [TaskItem(text: "Verify seeded UI test recording")],
            reminders: [],
            titles: [TitleItem(text: "UI Test Recording")],
            contentType: .meeting,
            aiEngine: "UITest",
            aiModel: "fixture",
            originalLength: segments.first?.text.count ?? 0,
            processingTime: 0.1
        )
    }

    private static func createSilentAudioFixture(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)

        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(sampleRate * 2.0)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }
}
#endif
