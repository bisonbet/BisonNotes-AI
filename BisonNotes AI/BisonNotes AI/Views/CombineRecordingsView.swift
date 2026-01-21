//
//  CombineRecordingsView.swift
//  BisonNotes AI
//
//  View for combining two recordings with order selection
//

import SwiftUI

struct CombineRecordingsView: View {
    let firstRecording: AudioRecordingFile
    let secondRecording: AudioRecordingFile
    let recommendedFirst: AudioRecordingFile
    
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    
    @State private var selectedFirst: AudioRecordingFile
    @State private var selectedSecond: AudioRecordingFile
    @State private var isCombining = false
    @State private var combineProgress: Double = 0.0
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var hasTranscriptsOrSummaries = false
    @State private var blockingMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var combinedRecordingURL: URL?
    @State private var combinedRecordingName: String?
    @State private var combinedRecordingDate: Date?
    @State private var combinedRecordingFileSize: Int64 = 0
    @State private var combinedRecordingDuration: TimeInterval = 0
    @State private var firstRecordingId: UUID?
    @State private var secondRecordingId: UUID?
    
    init(firstRecording: AudioRecordingFile, secondRecording: AudioRecordingFile, recommendedFirst: AudioRecordingFile) {
        self.firstRecording = firstRecording
        self.secondRecording = secondRecording
        self.recommendedFirst = recommendedFirst
        _selectedFirst = State(initialValue: recommendedFirst)
        _selectedSecond = State(initialValue: recommendedFirst == firstRecording ? secondRecording : firstRecording)
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    
                    if hasTranscriptsOrSummaries {
                        blockingMessageSection
                    } else {
                        orderSelectionSection
                        recordingPreviewSection
                        combineButton
                    }
                }
                .padding()
            }
            .navigationTitle("Combine Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
            }
            .alert("Delete Original Recordings?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    // User cancelled, just finish without deleting
                    finishCombining()
                }
                Button("Delete", role: .destructive) {
                    deleteOriginalRecordings()
                }
            } message: {
                Text("Do you want to delete the two original recordings? The combined recording will be kept.")
            }
            .onAppear {
                checkForTranscriptsAndSummaries()
            }
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Combine Recordings")
                .font(.title2)
                .fontWeight(.bold)
            
            if !hasTranscriptsOrSummaries {
                Text("Select which recording should be first in the combined file. The recordings will be merged in the order you specify.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var blockingMessageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cannot Combine Recordings")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if let message = blockingMessage {
                        Text(message)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.1))
            )
            
            VStack(alignment: .leading, spacing: 12) {
                Text("To combine these recordings:")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    instructionBullet(text: "Delete any existing transcripts from both recordings")
                    instructionBullet(text: "Delete any existing summaries from both recordings")
                    instructionBullet(text: "Then try combining again")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
        }
    }
    
    private func instructionBullet(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            
            Text(text)
                .font(.body)
                .foregroundColor(.secondary)
        }
    }
    
    private var orderSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording Order")
                .font(.headline)
            
            VStack(spacing: 12) {
                // First recording selection
                Button(action: {
                    swapRecordings()
                }) {
                    recordingOrderCard(
                        recording: selectedFirst,
                        position: "First",
                        isRecommended: selectedFirst.url == recommendedFirst.url
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                Image(systemName: "arrow.down")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                
                // Second recording selection
                recordingOrderCard(
                    recording: selectedSecond,
                    position: "Second",
                    isRecommended: false
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
    }
    
    private func recordingOrderCard(recording: AudioRecordingFile, position: String, isRecommended: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(position)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    if isRecommended {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                            Text("Recommended")
                                .font(.caption)
                        }
                        .foregroundColor(.green)
                    }
                }
                
                Text(recording.name)
                    .font(.body)
                    .fontWeight(.medium)
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
            }
            
            Spacer()
            
            if position == "First" {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.title3)
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
        )
    }
    
    private var recordingPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Combined Recording Preview")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Total Duration:")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatDuration(selectedFirst.duration + selectedSecond.duration))
                        .font(.body)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("First Recording:")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatDuration(selectedFirst.duration))
                        .font(.body)
                }
                
                HStack {
                    Text("Second Recording:")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatDuration(selectedSecond.duration))
                        .font(.body)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
            )
        }
    }
    
    private var combineButton: some View {
        Button(action: {
            Task {
                await combineRecordings()
            }
        }) {
            HStack {
                if isCombining {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                    Text("Combining...")
                } else {
                    Image(systemName: "link")
                    Text("Combine Recordings")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isCombining ? Color.gray : Color.blue)
            )
            .foregroundColor(.white)
        }
        .disabled(isCombining)
    }
    
    private func swapRecordings() {
        let temp = selectedFirst
        selectedFirst = selectedSecond
        selectedSecond = temp
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func checkForTranscriptsAndSummaries() {
        var issues: [String] = []
        
        // Check first recording
        if let firstEntry = appCoordinator.getRecording(url: firstRecording.url),
           let firstId = firstEntry.id {
            if appCoordinator.getTranscript(for: firstId) != nil {
                issues.append("'\(firstRecording.name)' has a transcript")
            }
            if appCoordinator.getSummary(for: firstId) != nil {
                issues.append("'\(firstRecording.name)' has a summary")
            }
        }
        
        // Check second recording
        if let secondEntry = appCoordinator.getRecording(url: secondRecording.url),
           let secondId = secondEntry.id {
            if appCoordinator.getTranscript(for: secondId) != nil {
                issues.append("'\(secondRecording.name)' has a transcript")
            }
            if appCoordinator.getSummary(for: secondId) != nil {
                issues.append("'\(secondRecording.name)' has a summary")
            }
        }
        
        if !issues.isEmpty {
            hasTranscriptsOrSummaries = true
            blockingMessage = issues.joined(separator: "\n")
        } else {
            hasTranscriptsOrSummaries = false
            blockingMessage = nil
        }
    }
    
    private func combineRecordings() async {
        // Double-check before combining
        checkForTranscriptsAndSummaries()
        guard !hasTranscriptsOrSummaries else {
            await MainActor.run {
                errorMessage = "Cannot combine recordings with existing transcripts or summaries. Please delete them first."
                showingError = true
            }
            return
        }
        
        isCombining = true
        errorMessage = nil
        
        do {
            // Create output URL
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = Date().timeIntervalSince1970
            let outputFilename = "combined_\(Int(timestamp)).m4a"
            let outputURL = documentsPath.appendingPathComponent(outputFilename)
            
            // Combine the recordings
            let combiner = RecordingCombiner.shared
            let combinedURL = try await combiner.combineRecordings(
                firstURL: selectedFirst.url,
                secondURL: selectedSecond.url,
                outputURL: outputURL
            )
            
            // Get date for the second recording (used for combined recording name)
            let secondDate = combiner.getRecordingDate(from: selectedSecond.url) ?? selectedSecond.date
            // Use the second recording's date for the combined recording name
            let combinedDate = secondDate
            
            // Calculate combined duration
            let combinedDuration = selectedFirst.duration + selectedSecond.duration
            
            // Get file size of combined recording
            let fileSize: Int64
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: combinedURL.path)
                if let size = attributes[.size] as? Int64 {
                    fileSize = size
                } else {
                    fileSize = 0
                }
            } catch {
                fileSize = 0
            }
            
            // Use default quality (whisperOptimized) for combined recordings
            let quality = AudioQuality.whisperOptimized
            
            // Create recording name using the second recording's date/time
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            let dateTimeString = dateFormatter.string(from: combinedDate)
            let combinedName = "combined recording \(dateTimeString)"
            
            // Get recording IDs for potential deletion
            let firstEntry = appCoordinator.getRecording(url: selectedFirst.url)
            let secondEntry = appCoordinator.getRecording(url: selectedSecond.url)
            
            // Get location data from both recordings
            // Try getLocationData first (from Core Data fields), then loadLocationData (from file)
            let firstLocation: LocationData? = {
                guard let entry = firstEntry else {
                    print("📍 Combine: First recording entry not found")
                    return nil
                }
                // First try Core Data fields
                if let location = appCoordinator.coreDataManager.getLocationData(for: entry) {
                    print("📍 Combine: Found first location from Core Data: \(location.coordinateString)")
                    return location
                }
                // Fallback to file-based location
                if let location = appCoordinator.loadLocationData(for: entry) {
                    print("📍 Combine: Found first location from file: \(location.coordinateString)")
                    return location
                }
                print("📍 Combine: No location found for first recording")
                return nil
            }()
            
            let secondLocation: LocationData? = {
                guard let entry = secondEntry else {
                    print("📍 Combine: Second recording entry not found")
                    return nil
                }
                // First try Core Data fields
                if let location = appCoordinator.coreDataManager.getLocationData(for: entry) {
                    print("📍 Combine: Found second location from Core Data: \(location.coordinateString)")
                    return location
                }
                // Fallback to file-based location
                if let location = appCoordinator.loadLocationData(for: entry) {
                    print("📍 Combine: Found second location from file: \(location.coordinateString)")
                    return location
                }
                print("📍 Combine: No location found for second recording")
                return nil
            }()
            
            // Determine which location to use:
            // - If both have location, use first recording's location
            // - If only one has location, use that one
            // - If neither has location, use nil
            let combinedLocation: LocationData?
            if let firstLoc = firstLocation, secondLocation != nil {
                // Both have location - use first recording's location
                combinedLocation = firstLoc
                print("📍 Combine: Both recordings have location, using first: \(firstLoc.coordinateString)")
            } else if let firstLoc = firstLocation {
                // Only first has location
                combinedLocation = firstLoc
                print("📍 Combine: Only first has location, using it: \(firstLoc.coordinateString)")
            } else if let secondLoc = secondLocation {
                // Only second has location
                combinedLocation = secondLoc
                print("📍 Combine: Only second has location, using it: \(secondLoc.coordinateString)")
            } else {
                // Neither has location
                combinedLocation = nil
                print("📍 Combine: Neither recording has location")
            }
            
            // Store values for confirmation dialog
            await MainActor.run {
                combinedRecordingURL = combinedURL
                combinedRecordingName = combinedName
                combinedRecordingDate = combinedDate
                combinedRecordingFileSize = fileSize
                combinedRecordingDuration = combinedDuration
                firstRecordingId = firstEntry?.id
                secondRecordingId = secondEntry?.id
                
                // Log location data before adding
                if let location = combinedLocation {
                    print("📍 Combine: Passing location to addRecording: \(location.coordinateString), address: \(location.address ?? "none")")
                } else {
                    print("📍 Combine: No location to pass to addRecording")
                }
                
                // Add to Core Data first
                let recordingId = appCoordinator.addRecording(
                    url: combinedURL,
                    name: combinedName,
                    date: combinedDate,
                    fileSize: fileSize,
                    duration: combinedDuration,
                    quality: quality,
                    locationData: combinedLocation
                )
                
                // Verify location was saved
                if let savedRecording = appCoordinator.getRecording(id: recordingId) {
                    let savedLocation = appCoordinator.coreDataManager.getLocationData(for: savedRecording)
                    if let savedLoc = savedLocation {
                        print("✅ Combine: Location verified in saved recording: \(savedLoc.coordinateString)")
                    } else {
                        print("❌ Combine: Location NOT found in saved recording!")
                        print("   Recording ID: \(recordingId)")
                        print("   Latitude: \(savedRecording.locationLatitude)")
                        print("   Longitude: \(savedRecording.locationLongitude)")
                    }
                }
                
                // Post notification to refresh views
                NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
                
                // Show confirmation dialog for deleting originals
                showingDeleteConfirmation = true
                isCombining = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showingError = true
                isCombining = false
            }
        }
    }
    
    private func finishCombining() {
        // Just dismiss - recording already added
        dismiss()
    }
    
    private func deleteOriginalRecordings() {
        // Delete the original recordings if they exist in Core Data
        if let firstId = firstRecordingId {
            appCoordinator.deleteRecording(id: firstId)
        }
        if let secondId = secondRecordingId {
            appCoordinator.deleteRecording(id: secondId)
        }
        
        // Post notification to refresh views
        NotificationCenter.default.post(name: NSNotification.Name("RecordingAdded"), object: nil)
        
        dismiss()
    }
    
}
