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
                let _ = print("🗑️ Sheet is being presented")
                let _ = print("🗑️ recordingToDelete in sheet: \(deletionData.recordingToDelete?.name ?? "nil")")
                let _ = print("🗑️ fileRelationships in sheet: \(deletionData.fileRelationships != nil ? "exists" : "nil")")
                
                if let recording = deletionData.recordingToDelete, let relationships = deletionData.fileRelationships {
                    let _ = print("🗑️ Creating EnhancedDeleteDialog")
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
                    let _ = print("🗑️ Showing fallback dialog")
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
                .onAppear {
                    print("🎵 Creating AudioPlayerView for: \(recording.name)")
                }
            }
        }
        .onAppear {
            loadRecordings()
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
                print("🎵 Opening audio player for: \(recording.name)")
                print("🎵 Setting selectedRecordingForPlayer to: \(recording)")
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
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            recordings = fileURLs
                .filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
                .compactMap { url -> AudioRecordingFile? in
                    guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                    let duration = getRecordingDuration(url: url)
                    let locationData = loadLocationDataForRecording(url: url)
                    return AudioRecordingFile(url: url, name: url.deletingPathExtension().lastPathComponent, date: creationDate, duration: duration, locationData: locationData)
                }
                .sorted { $0.date > $1.date }
            
            // Geocode locations for all recordings
            for recording in recordings {
                loadLocationAddress(for: recording)
            }
        } catch {
            print("Error loading recordings: \(error)")
        }
    }
    
    private func loadLocationDataForRecording(url: URL) -> LocationData? {
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
    
    private func loadLocationAddress(for recording: AudioRecordingFile) {
        guard let locationData = recording.locationData else { return }
        
        let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
        // Use a default location manager since AudioRecorderViewModel doesn't have one
        let locationManager = LocationManager()
        locationManager.reverseGeocodeLocation(location) { address in
            if let address = address {
                locationAddresses[recording.url] = address
            }
        }
    }
    
    private func deleteRecording(_ recording: AudioRecordingFile) {
        print("🗑️ deleteRecording called for: \(recording.name)")
        print("🗑️ recordingToDelete before: \(deletionData.recordingToDelete?.name ?? "nil")")
        
        // Set the recording to delete immediately
        deletionData.recordingToDelete = recording
        print("🗑️ recordingToDelete set immediately: \(deletionData.recordingToDelete?.name ?? "nil")")
        
        // Set up relationships for enhanced deletion
        Task {
            print("🗑️ Starting relationship setup for: \(recording.url)")
            
            // First try to get existing relationships
            var relationships = enhancedFileManager.getFileRelationships(for: recording.url)
            print("🗑️ Initial relationships: \(relationships != nil ? "found" : "nil")")
            
            // If no relationships exist, create them on demand
            if relationships == nil {
                print("🗑️ No relationships found, refreshing...")
                await enhancedFileManager.refreshRelationships(for: recording.url)
                relationships = enhancedFileManager.getFileRelationships(for: recording.url)
                print("🗑️ After refresh relationships: \(relationships != nil ? "found" : "nil")")
            }
            
            await MainActor.run {
                print("🗑️ MainActor: setting up dialog")
                print("🗑️ recordingToDelete in MainActor: \(self.deletionData.recordingToDelete?.name ?? "nil")")
                
                if let relationships = relationships {
                    // Use enhanced deletion with relationships
                    print("🗑️ Setting fileRelationships")
                    print("🗑️ Relationships details:")
                    print("   - Recording URL: \(relationships.recordingURL?.lastPathComponent ?? "nil")")
                    print("   - Recording Name: \(relationships.recordingName)")
                    print("   - Transcript Exists: \(relationships.transcriptExists)")
                    print("   - Summary Exists: \(relationships.summaryExists)")
                    print("   - Has Recording: \(relationships.hasRecording)")
                    print("   - Availability Status: \(relationships.availabilityStatus)")
                    
                    self.deletionData.fileRelationships = relationships
                    print("🗑️ fileRelationships set: \(self.deletionData.fileRelationships != nil ? "yes" : "no")")
                    
                    self.showingEnhancedDeleteDialog = true
                    print("🗑️ showingEnhancedDeleteDialog set to true")
                    
                    // Log dialog setup details
                    if let recording = self.deletionData.recordingToDelete, let relationships = self.deletionData.fileRelationships {
                        print("🗑️ Dialog setup - Recording: \(recording.name)")
                        print("🗑️ Dialog setup - Relationships: \(relationships.recordingName)")
                    }
                } else {
                    print("🗑️ No relationships available, falling back to simple deletion")
                    // Fallback to simple deletion if we still can't get relationships
                    do {
                        try FileManager.default.removeItem(at: recording.url)
                        loadRecordings() // Reload the list
                        print("🗑️ Simple deletion completed")
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
}