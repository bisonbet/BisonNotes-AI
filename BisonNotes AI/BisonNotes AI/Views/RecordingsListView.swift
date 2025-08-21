//
//  RecordingsListView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import CoreLocation
import AVFoundation

typealias AudioRecordingFile = RecordingFile

class DeletionData: ObservableObject {
    @Published var recordingToDelete: AudioRecordingFile?
    @Published var fileRelationships: FileRelationships?
}

struct RecordingsListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @StateObject private var deletionData = DeletionData()
    @State private var recordings: [AudioRecordingFile] = []
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var preserveSummaryOnDelete = false
    @State private var showingEnhancedDeleteDialog = false
    @State private var selectedRecordingForPlayer: AudioRecordingFile?
    
    var body: some View {
        NavigationView {
            VStack {
                // Custom header
                HStack {
                    Text("Recordings")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .font(.headline)
                }
                .padding()
                
                recordingsContent
            }
            .sheet(isPresented: $showingEnhancedDeleteDialog) {
                if let recording = deletionData.recordingToDelete, let relationships = deletionData.fileRelationships {
                    EnhancedDeleteDialog(
                        recording: recording,
                        relationships: relationships,
                        preserveSummary: $preserveSummaryOnDelete,
                        onConfirm: {
                            Task {
                                await deleteRecordingWithRelationships(recording, preserveSummary: preserveSummaryOnDelete)
                            }
                            showingEnhancedDeleteDialog = false
                        },
                        onCancel: {
                            showingEnhancedDeleteDialog = false
                        }
                    )
                } else {
                    // Loading or error state
                    VStack(spacing: 20) {
                        if deletionData.recordingToDelete != nil {
                            // Loading state
                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text("Preparing deletion options...")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            // Error state
                            VStack(spacing: 16) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 40))
                                    .foregroundColor(.orange)
                                Text("Unable to prepare deletion")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                Text("Please try again")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Button("Cancel") {
                            showingEnhancedDeleteDialog = false
                            deletionData.recordingToDelete = nil
                            deletionData.fileRelationships = nil
                        }
                        .padding()
                    }
                    .padding()
                }
            }
            .sheet(item: $selectedLocationData) { locationData in
                LocationDetailView(locationData: locationData)
            }
            .sheet(item: $selectedRecordingForPlayer) { recording in
                VStack {
                    Text("Audio Player Test")
                        .font(.title)
                        .padding()
                    Text("Recording: \(recording.name)")
                        .padding()
                    AudioPlayerView(recording: recording)
                        .environmentObject(recorderVM)
                }
            }
        }
        .onAppear {
            refreshFileRelationships()
            loadRecordings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryCreated"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryDeleted"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingRenamed"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingAdded"))) { _ in
            loadRecordings()
            refreshFileRelationships()
        }
    }
    

    

    
    private var recordingsContent: some View {
        Group {
            if recordings.isEmpty {
                emptyStateView
            } else {
                recordingsListView
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Recordings")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            Text("Start recording or import audio files to see them here")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var recordingsListView: some View {
        List {
            ForEach(recordings) { recording in
                recordingRow(for: recording)
            }
        }
    }
    
    private func recordingRow(for recording: AudioRecordingFile) -> some View {
        HStack {
            // Main content area - clickable for playback
            Button(action: {
                selectedRecordingForPlayer = recording
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    
                    HStack {
                        Text(recording.dateString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(recording.durationString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // File availability indicator
                    if let relationships = enhancedFileManager.getFileRelationships(for: recording.url) {
                        FileAvailabilityIndicator(
                            status: relationships.availabilityStatus,
                            showLabel: true,
                            size: .small
                        )
                    }
                    
                    if let locationData = recording.locationData {
                        HStack {
                            Image(systemName: "location.fill")
                                .font(.caption)
                            Text("View Location")
                                .font(.caption)
                        }
                        .foregroundColor(.accentColor)
                        .onTapGesture {
                            showLocationDetails(locationData)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PlainButtonStyle())
            
            Spacer()
            
            // Action buttons - separate from main clickable area
            HStack(spacing: 12) {
                Button(action: {
                    selectedRecordingForPlayer = recording
                }) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: {
                    deletionData.recordingToDelete = recording
                    deleteRecording(recording)
                }) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }
    
    private func loadRecordings() {
        // Use the app coordinator to get recordings with proper database names
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()

        // Deduplicate by resolved filename; prefer entries with content and non-generic titles
        var bestByFilename: [String: (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] = [:]

        func score(_ e: (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)) -> Int {
            var s = 0
            if e.summary != nil { s += 3 }
            if e.transcript != nil { s += 2 }
            if let name = e.recording.recordingName, !isGenericName(name) { s += 1 }
            if e.recording.duration > 0 { s += 1 }
            return s
        }

        for entry in recordingsWithData {
            guard let url = appCoordinator.getAbsoluteURL(for: entry.recording) else { continue }
            let key = url.lastPathComponent
            if let existing = bestByFilename[key] {
                bestByFilename[key] = score(existing) >= score(entry) ? existing : entry
            } else {
                bestByFilename[key] = entry
            }
        }

        let deduped = Array(bestByFilename.values)

        recordings = deduped.compactMap { recordingData -> AudioRecordingFile? in
            let recording = recordingData.recording
            guard let recordingName = recording.recordingName,
                  let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                  FileManager.default.fileExists(atPath: recordingURL.path) else {
                print("⚠️ Skipping recording with missing data: \(recording.recordingName ?? "unknown")")
                return nil
            }
            

            let date = recording.recordingDate ?? recording.createdAt ?? Date()
            let duration = recording.duration > 0 ? recording.duration : getRecordingDuration(url: recordingURL)
            let locationData = appCoordinator.loadLocationData(for: recording)

            return AudioRecordingFile(
                url: recordingURL,
                name: recordingName,
                date: date,
                duration: duration,
                locationData: locationData
            )
        }
        .sorted { $0.date > $1.date }

        // Geocode locations for all recordings (with rate limiting)
        loadLocationAddressesBatch(for: recordings)
    }

    private func isGenericName(_ name: String) -> Bool {
        if name.hasPrefix("recording_") { return true }
        if name.hasPrefix("V20210426-") || name.hasPrefix("V20210427-") { return true }
        if name.hasPrefix("apprecording-") { return true }
        if name.hasPrefix("importedfile-recording_") { return true }
        if name.count > 20 && (name.contains("1754") || name.contains("2025") || name.contains("2024")) { return true }
        return false
    }
    
    private func loadLocationDataForRecording(url: URL) -> LocationData? {
        // First try to find the recording in Core Data and use proper URL resolution
        if let recording = appCoordinator.getRecording(url: url) {
            return appCoordinator.loadLocationData(for: recording)
        }
        
        // Fallback: try direct file access for recordings not yet in Core Data
        let locationURL = url.deletingPathExtension().appendingPathExtension("location")
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }
        return locationData
    }
    
    private func showLocationDetails(_ locationData: LocationData) {
        selectedLocationData = locationData
    }
    
    private func loadLocationAddressesBatch(for recordings: [AudioRecordingFile]) {
        // Filter recordings that have location data and don't already have cached addresses
        let recordingsNeedingGeocode = recordings.filter { recording in
            guard let _ = recording.locationData else { return false }
            return locationAddresses[recording.url] == nil
        }
        
        // Process recordings one by one to respect rate limiting
        for recording in recordingsNeedingGeocode {
            loadLocationAddress(for: recording)
        }
    }
    
    private func loadLocationAddress(for recording: AudioRecordingFile) {
        guard let locationData = recording.locationData else { return }
        
        // Skip if we already have an address for this recording
        if locationAddresses[recording.url] != nil {
            return
        }
        
        let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
        // Use a default location manager since AudioRecorderViewModel doesn't have one
        let locationManager = LocationManager()
        locationManager.reverseGeocodeLocation(location) { address in
            if let address = address {
                self.locationAddresses[recording.url] = address
            }
        }
    }
    
    private func deleteRecording(_ recording: AudioRecordingFile) {
        // Set the recording to delete immediately
        deletionData.recordingToDelete = recording
        
        // Set up relationships for enhanced deletion
        Task {
            // First try to get existing relationships
            var relationships = enhancedFileManager.getFileRelationships(for: recording.url)
            
            // If no relationships exist, create them on demand
            if relationships == nil {
                await enhancedFileManager.refreshRelationships(for: recording.url)
                relationships = enhancedFileManager.getFileRelationships(for: recording.url)
            }
            
            await MainActor.run {
                if let relationships = relationships {
                    // Use enhanced deletion with relationships
                    self.deletionData.fileRelationships = relationships
                    self.showingEnhancedDeleteDialog = true
                } else {
                    // Fallback to simple deletion if we still can't get relationships
                    do {
                        try FileManager.default.removeItem(at: recording.url)
                        loadRecordings() // Reload the list
                    } catch {
                        print("Failed to delete recording: \(error)")
                    }
                }
            }
        }
    }
    
    private func deleteRecordingWithRelationships(_ recording: AudioRecordingFile, preserveSummary: Bool) async {
        do {
            try await enhancedFileManager.deleteRecording(recording.url, preserveSummary: preserveSummary)
            await MainActor.run {
                loadRecordings() // Reload the list
            }
        } catch {
            print("Failed to delete recording with relationships: \(error)")
        }
    }
    
    private func getRecordingDuration(url: URL) -> TimeInterval {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            return player.duration
        } catch {
            print("Error getting duration for \(url.lastPathComponent): \(error)")
            return 0.0
        }
    }
    
    private func refreshFileRelationships() {
        Task {
            // Refresh relationships for all recordings in the background
            for recording in recordings {
                await enhancedFileManager.refreshRelationships(for: recording.url)
            }
            
            await MainActor.run {
                // Force a UI refresh by updating the published object
                enhancedFileManager.objectWillChange.send()
            }
        }
    }
    
    // MARK: - Helper Methods
    
}