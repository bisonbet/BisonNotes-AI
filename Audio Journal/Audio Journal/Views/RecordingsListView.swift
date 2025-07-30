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
    @StateObject private var importManager = FileImportManager()
    @StateObject private var documentPickerCoordinator = DocumentPickerCoordinator()
    @StateObject private var transcriptManager = TranscriptManager.shared
    @StateObject private var summaryManager = SummaryManager()
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @State private var recordings: [AudioRecordingFile] = []
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var showingDocumentPicker = false
    @State private var recordingToDelete: AudioRecordingFile?
    @State private var showingDeleteConfirmation = false
    @State private var preserveSummaryOnDelete = false
    
    var body: some View {
        NavigationView {
            VStack {
                // Import button
                HStack {
                    Spacer()
                    Button(action: {
                        documentPickerCoordinator.selectAudioFiles { urls in
                            if !urls.isEmpty {
                                Task {
                                    await importManager.importAudioFiles(from: urls)
                                    loadRecordings() // Reload recordings after import
                                }
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Import Audio Files")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                    }
                    .disabled(importManager.isImporting)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                // Import progress
                if importManager.isImporting {
                    VStack(spacing: 8) {
                        ProgressView(value: importManager.importProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .padding(.horizontal, 20)
                        
                        Text(importManager.progressText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 10)
                }
                
                if recordings.isEmpty {
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
                } else {
                    List {
                        ForEach(recordings) { recording in
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
                                                // Show location details
                                                showLocationDetails(locationData)
                                            }) {
                                                HStack {
                                                    Image(systemName: "location.fill")
                                                        .font(.caption2)
                                                        .foregroundColor(.accentColor)
                                                    Text(locationAddresses[recording.url] ?? locationData.coordinateString)
                                                        .font(.caption2)
                                                        .foregroundColor(.accentColor)
                                                }
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                    Spacer()
                                    HStack(spacing: 12) {
                                        Button(action: {
                                            if recorderVM.currentlyPlayingURL == recording.url && recorderVM.isPlaying {
                                                recorderVM.pausePlayback()
                                            } else if recorderVM.currentlyPlayingURL == recording.url {
                                                recorderVM.playRecording(url: recording.url)
                                            } else {
                                                recorderVM.playRecording(url: recording.url)
                                            }
                                        }) {
                                            Image(systemName: recorderVM.currentlyPlayingURL == recording.url ? (recorderVM.isPlaying ? "pause.circle.fill" : "play.circle.fill") : "play.circle.fill")
                                                .foregroundColor(recorderVM.currentlyPlayingURL == recording.url ? (recorderVM.isPlaying ? .red : .green) : .accentColor)
                                                .font(.title2)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        Button(action: {
                                            recordingToDelete = recording
                                            showingDeleteConfirmation = true
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                                .font(.title3)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        recorderVM.stopPlayback()
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedLocationData) { locationData in
                LocationDetailView(locationData: locationData)
            }
            .sheet(isPresented: $documentPickerCoordinator.isShowingPicker) {
                AudioDocumentPicker(isPresented: $documentPickerCoordinator.isShowingPicker, coordinator: documentPickerCoordinator)
            }
            .alert("Import Complete", isPresented: $importManager.showingImportAlert) {
                Button("OK") {
                    importManager.importResults = nil
                }
            } message: {
                if let results = importManager.importResults {
                    Text(results.summary)
                }
            }
            .alert("Delete Recording", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    recordingToDelete = nil
                    preserveSummaryOnDelete = false
                }
                
                if let recording = recordingToDelete,
                   let relationships = enhancedFileManager.getFileRelationships(for: recording.url),
                   relationships.summaryExists {
                    Button("Delete All", role: .destructive) {
                        if let recording = recordingToDelete {
                            deleteRecording(recording, preserveSummary: false)
                        }
                        recordingToDelete = nil
                        preserveSummaryOnDelete = false
                    }
                    
                    Button("Keep Summary") {
                        if let recording = recordingToDelete {
                            deleteRecording(recording, preserveSummary: true)
                        }
                        recordingToDelete = nil
                        preserveSummaryOnDelete = false
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        if let recording = recordingToDelete {
                            deleteRecording(recording, preserveSummary: false)
                        }
                        recordingToDelete = nil
                        preserveSummaryOnDelete = false
                    }
                }
            } message: {
                if let recording = recordingToDelete,
                   let relationships = enhancedFileManager.getFileRelationships(for: recording.url) {
                    if relationships.summaryExists {
                        Text("What would you like to do with '\(recording.name)'?\n\n• Delete All: Removes recording, transcript, and summary\n• Keep Summary: Removes recording and transcript but preserves the summary for future reference\n\nThis action cannot be undone.")
                    } else {
                        Text("Are you sure you want to delete '\(recording.name)'? This will also delete any associated transcript. This action cannot be undone.")
                    }
                }
            }
        }
        .onAppear {
            loadRecordings()
            // Refresh file relationships when view appears
            enhancedFileManager.refreshAllRelationships()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingRenamed"))) { _ in
            // Refresh recordings list when a recording is renamed
            print("🔄 RecordingsListView: Received recording renamed notification, refreshing list")
            loadRecordings()
        }
    }
    
    private func loadRecordings() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: [.creationDateKey], options: [])
            recordings = fileURLs
                .filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
                .compactMap { url -> AudioRecordingFile? in
                    guard let creationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                    let duration = recorderVM.getRecordingDuration(url: url)
                    let locationData = loadLocationDataForRecording(url: url)
                    return AudioRecordingFile(url: url, name: url.deletingPathExtension().lastPathComponent, date: creationDate, duration: duration, locationData: locationData)
                }
                .sorted { $0.date > $1.date }
            
            // Geocode locations for all recordings
            for recording in recordings {
                geocodeLocationForRecording(recording)
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
    
    private func geocodeLocationForRecording(_ recording: AudioRecordingFile) {
        guard let locationData = recording.locationData else { return }
        
        let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
        recorderVM.locationManager.reverseGeocodeLocation(location) { address in
            if let address = address {
                locationAddresses[recording.url] = address
            }
        }
    }
    
    private func deleteRecording(_ recording: AudioRecordingFile, preserveSummary: Bool = false) {
        // Stop playback if this recording is currently playing
        if recorderVM.currentlyPlayingURL == recording.url {
            recorderVM.stopPlayback()
        }
        
        Task {
            do {
                // Use EnhancedFileManager for selective deletion
                try await enhancedFileManager.deleteRecording(recording.url, preserveSummary: preserveSummary)
                
                // Reload the list on main thread
                await MainActor.run {
                    loadRecordings()
                }
                
                print("✅ Recording deletion completed: \(recording.name) (preserve summary: \(preserveSummary))")
            } catch {
                print("❌ Error deleting recording: \(error)")
                // TODO: Show error alert to user
            }
        }
    }
}