//
//  BisonNotes_AI_Watch_AppTests.swift
//  BisonNotes AI Watch AppTests
//
//  Created by Tim Champ on 8/17/25.
//

import Foundation
import Testing
@testable import BisonNotes_AI_Watch_App

struct BisonNotes_AI_Watch_AppTests {

    @MainActor
    @Test func localRecordingStoragePersistsStatusAndMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchRecordingStorageTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.m4a")
        try Data(repeating: 7, count: 1_024).write(to: sourceURL)

        let storage = WatchRecordingStorage(baseDirectoryURL: directory)
        let recordingId = UUID()
        let metadata = try #require(storage.saveRecording(audioFileURL: sourceURL, sessionId: recordingId, duration: 12))

        #expect(metadata.id == recordingId)
        #expect(metadata.syncStatus == .local)
        #expect(storage.getRecordingsPendingSync().map(\.id) == [recordingId])
        #expect(storage.calculateChecksum(for: metadata) != nil)

        let location = WatchLocationData(latitude: 42.0, longitude: -71.0, timestamp: Date(), accuracy: 5)
        let updated = try #require(storage.updateLocation(recordingId, location: location))
        #expect(updated.locationData == location)

        storage.updateSyncStatus(recordingId, status: .pendingSync, attempts: 1)
        #expect(storage.getRecordingsPendingSync().first?.syncStatus == .pendingSync)

        storage.updateSyncStatus(recordingId, status: .synced, attempts: 2)
        #expect(storage.getRecordingsPendingSync().isEmpty)
        #expect(storage.getSyncedRecordings().map(\.id) == [recordingId])

        let reloaded = WatchRecordingStorage(baseDirectoryURL: directory)
        #expect(reloaded.localRecordings.map(\.id) == [recordingId])

        reloaded.deleteRecording(metadata)
        #expect(reloaded.localRecordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: reloaded.fileURL(for: metadata).path))
    }
}
