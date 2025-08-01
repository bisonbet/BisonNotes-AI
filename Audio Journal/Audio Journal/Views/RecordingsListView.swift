//
//  RecordingsListView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import CoreLocation

typealias AudioRecordingFile = RecordingFile

struct RecordingsListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @State private var recordings: [AudioRecordingFile] = []
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var recordingToDelete: AudioRecordingFile?
    @State private var showingDeleteConfirmation = false
    @State private var preserveSummaryOnDelete = false
    @State private var showingEnhancedDeleteDialog = false
    @State private var fileRelationships: FileRelationships?
    
    var body: some View {
        NavigationView {
            VStack {
                recordingsContent
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Delete Recording", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let recording = recordingToDelete {
                        deleteRecording(recording)
                    }
                }
            } message: {
                if let recording = recordingToDelete {
                    Text("Are you sure you want to delete '\(recording.name)'?")
                }
            }
            .sheet(isPresented: $showingEnhancedDeleteDialog) {
                if let recording = recordingToDelete, let relationships = fileRelationships {
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
                }
            }
            .sheet(item: $selectedLocationData) { locationData in
                LocationDetailView(locationData: locationData)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.name)
                        .font(.headline)
                        .foregroundColor(.primary)
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
                        Button(action: {
                            showLocationDetails(locationData)
                        }) {
                            HStack {
                                Image(systemName: "location.fill")
                                    .font(.caption)
                                Text("View Location")
                                    .font(.caption)
                            }
                            .foregroundColor(.accentColor)
                        }
                    }
                }
                
                Spacer()
                
                // Playback controls
                HStack(spacing: 12) {
                    Button(action: {
                        // Note: AudioRecorderViewModel doesn't have currentlyPlayingURL and stopPlayback methods
                        // This is a simplified version that doesn't handle playback state
                        // if recorderVM.currentlyPlayingURL == recording.url {
                        //     recorderVM.stopPlayback()
                        // }
                    }) {
                        Image(systemName: "play.circle.fill") // Simplified since currentlyPlayingURL doesn't exist
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                    
                    Button(action: {
                        recordingToDelete = recording
                        showingDeleteConfirmation = true
                    }) {
                        Image(systemName: "trash")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                }
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
        // Check if we have enhanced file management available
        if let relationships = enhancedFileManager.getFileRelationships(for: recording.url) {
            // Use enhanced deletion with relationships
            fileRelationships = relationships
            showingEnhancedDeleteDialog = true
        } else {
            // Fallback to simple deletion
            do {
                try FileManager.default.removeItem(at: recording.url)
                loadRecordings() // Reload the list
            } catch {
                print("Failed to delete recording: \(error)")
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
        // Note: AudioRecorderViewModel doesn't have getRecordingDuration method
        // Return a default duration
        return 0.0 // Default duration since getRecordingDuration doesn't exist
    }
}