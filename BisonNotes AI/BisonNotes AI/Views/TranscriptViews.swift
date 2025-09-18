//
//  TranscriptViews.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import AVFoundation
import Speech
import CoreLocation

struct TranscriptsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @ObservedObject private var backgroundProcessingManager = BackgroundProcessingManager.shared
    @State private var recordings: [(recording: RecordingEntry, transcript: TranscriptData?)] = []
    @State private var selectedRecording: RecordingEntry?
    @State private var isGeneratingTranscript = false
    @State private var generatingTranscriptRecording: RecordingEntry?
    @State private var selectedLocationData: LocationData?
    @State private var locationAddresses: [URL: String] = [:]
    @State private var showingTranscriptionCompletionAlert = false
    @State private var completedTranscriptionText = ""
    @State private var isCheckingForCompletions = false
    @State private var refreshTrigger = false
    @State private var refreshTimer: Timer?
    @State private var isShowingAlert = false
    
    var body: some View {
        NavigationView {
            mainContentView
        }
        .sheet(item: $selectedRecording) { recording in
            if let recordingId = recording.id,
               let transcript = appCoordinator.getTranscriptData(for: recordingId) {
                EditableTranscriptView(recording: recording, transcript: transcript, transcriptManager: TranscriptManager.shared)
            } else {
                TranscriptDetailView(recording: recording, transcriptText: "")
            }
        }
        .sheet(item: $selectedLocationData) { locationData in
            LocationDetailView(locationData: locationData)
        }
        .alert("Transcription Complete", isPresented: $showingTranscriptionCompletionAlert) {
            Button("OK") {
                showingTranscriptionCompletionAlert = false
                isShowingAlert = false
            }
        } message: {
            Text(completedTranscriptionText.isEmpty ? "A background transcription has completed. The transcript is now available for editing." : completedTranscriptionText)
        }
        .onChange(of: showingTranscriptionCompletionAlert) { _, newValue in
            isShowingAlert = newValue
        }
    }
    
    private var mainContentView: some View {
        VStack {
            if recordings.isEmpty {
                emptyStateView
            } else {
                recordingsListView
            }
        }
        .navigationTitle("Transcripts")
        // Toolbar status checker removed per request
        .onAppear {
            loadRecordings()
            setupTranscriptionCompletionCallback()
            // Force UI refresh to ensure transcript states are properly displayed
            DispatchQueue.main.async {
                self.refreshTrigger.toggle()
            }
            
            // Start periodic refresh timer
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                DispatchQueue.main.async {
                    self.loadRecordings()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingRenamed"))) { _ in
            // Refresh recordings list when a recording is renamed
            print("🔄 TranscriptViews: Received recording renamed notification, refreshing list")
            loadRecordings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { _ in
            // Refresh recordings list when transcription completes
            print("🔄 TranscriptViews: Received transcription completed notification, refreshing list")
            DispatchQueue.main.async {
                self.loadRecordings()
                self.refreshTrigger.toggle()
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Recordings Found")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            Text("Record some audio first to generate transcripts")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var recordingsListView: some View {
        List {
            ForEach(recordings.indices, id: \.self) { index in
                recordingRowView(recordings[index])
            }
        }
    }
    
    private func recordingRowView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                recordingInfoView(recordingData)
                Spacer()
                transcriptButtonView(recordingData)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func recordingInfoView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recordingData.recording.recordingName ?? "Unknown Recording")
                .font(.headline)
                .foregroundColor(.primary)
            Text(UserPreferences.shared.formatMediumDateTime(recordingData.recording.recordingDate ?? Date()))
                .font(.caption)
                .foregroundColor(.secondary)
            if let recordingURL = appCoordinator.getAbsoluteURL(for: recordingData.recording),
               let locationData = loadLocationDataForRecording(url: recordingURL) {
                locationButtonView(locationData, recordingURL: recordingURL)
            }
        }
    }
    
    private func locationButtonView(_ locationData: LocationData, recordingURL: URL) -> some View {
        Button(action: {
            selectedLocationData = locationData
        }) {
            HStack {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                Text(locationAddresses[recordingURL] ?? locationData.coordinateString)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func transcriptButtonView(_ recordingData: (recording: RecordingEntry, transcript: TranscriptData?)) -> some View {
        let hasTranscript = recordingData.transcript != nil
        let isCurrentlyGenerating = isGeneratingTranscript && generatingTranscriptRecording?.id == recordingData.recording.id

        return Button(action: {
            if hasTranscript {
                // Show existing transcript for editing - always allowed
                selectedRecording = recordingData.recording
            } else {
                // Generate new transcript - only if not currently generating any transcript
                if !isGeneratingTranscript {
                    generateTranscript(for: recordingData.recording)
                }
            }
        }) {
            HStack {
                if isCurrentlyGenerating {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Generating...")
                        .font(.caption2)
                } else {
                    Image(systemName: hasTranscript ? "text.bubble.fill" : "text.bubble")
                    Text(hasTranscript ? "Edit Transcript" : "Generate Transcript")
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                hasTranscript ? Color.green :
                (isGeneratingTranscript && !hasTranscript) ? Color.gray : Color.accentColor
            )
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .disabled(isGeneratingTranscript && !hasTranscript) // Only disable generate buttons when generating
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .id("\(recordingData.recording.id?.uuidString ?? "unknown")-\(hasTranscript)-\(isGeneratingTranscript)-\(refreshTrigger)")
    }
    
    private func loadRecordings() {
		// Use Core Data to get recordings
		let recordingsWithData = appCoordinator.getAllRecordingsWithData()
		
		// Deduplicate by resolved filename; prefer items with transcript and non-generic titles
		var bestByFilename: [String: (recording: RecordingEntry, transcript: TranscriptData?)] = [:]
		
		func isGenericName(_ name: String) -> Bool {
			if name.hasPrefix("recording_") { return true }
			if name.hasPrefix("V20210426-") || name.hasPrefix("V20210427-") { return true }
			if name.hasPrefix("apprecording-") { return true }
			if name.hasPrefix("importedfile-recording_") { return true }
			if name.count > 20 && (name.contains("1754") || name.contains("2025") || name.contains("2024")) { return true }
			return false
		}
		
		func score(_ entry: (recording: RecordingEntry, transcript: TranscriptData?)) -> Int {
			var s = 0
			if entry.transcript != nil { s += 3 }
			if let name = entry.recording.recordingName, !isGenericName(name) { s += 2 }
			if entry.recording.summary != nil { s += 1 }
			if entry.recording.duration > 0 { s += 1 }
			return s
		}
		
		for rd in recordingsWithData {
			guard let url = appCoordinator.getAbsoluteURL(for: rd.recording) else { continue }
			let key = url.lastPathComponent
			let candidate = (recording: rd.recording, transcript: rd.transcript)
			if let existing = bestByFilename[key] {
				bestByFilename[key] = score(existing) >= score(candidate) ? existing : candidate
			} else {
				bestByFilename[key] = candidate
			}
		}
		
		let deduped = Array(bestByFilename.values)
		
		// Sort by date
		recordings = deduped.sorted { $0.recording.recordingDate ?? Date() > $1.recording.recordingDate ?? Date() }
		
		// Geocode locations for all recordings (with rate limiting)
		loadLocationAddressesBatch(for: recordings.map { $0.recording })
    }
    
    func loadLocationDataForRecording(url: URL) -> LocationData? {
        // Find the recording entry by URL
        guard let recording = appCoordinator.getRecording(url: url) else {
            return nil
        }
        
        // Use the proper location loading system
        return appCoordinator.loadLocationData(for: recording)
    }
    
    static func loadLocationDataForRecording(url: URL) -> LocationData? {
        // Legacy static method - try direct file access as fallback
        let locationURL = url.deletingPathExtension().appendingPathExtension("location")
        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }
        return locationData
    }
    
    private func loadLocationAddressesBatch(for recordings: [RecordingEntry]) {
        // Filter recordings that have location data and don't already have cached addresses
        let recordingsNeedingGeocode = recordings.filter { recording in
            guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                  let _ = appCoordinator.loadLocationData(for: recording) else { return false }
            return locationAddresses[recordingURL] == nil
        }
        
        // Process recordings one by one to respect rate limiting
        for recording in recordingsNeedingGeocode {
            loadLocationAddress(for: recording)
        }
    }
    
    private func loadLocationAddress(for recording: RecordingEntry) {
        // Use async dispatch to avoid blocking main thread
        Task {
            // Use the proper location loading system
            guard let locationData = appCoordinator.loadLocationData(for: recording),
                  let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                return
            }
            
            // Skip if we already have an address for this recording
            if locationAddresses[recordingURL] != nil {
                return
            }
            
            await MainActor.run {
                let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
                // Use a default location manager since AudioRecorderViewModel doesn't have one
                let locationManager = LocationManager()
                locationManager.reverseGeocodeLocation(location) { address in
                    if let address = address {
                        self.locationAddresses[recordingURL] = address
                    }
                }
            }
        }
    }
    
    private func forceRefreshUI() {
        DispatchQueue.main.async {
            self.refreshTrigger.toggle()
            self.loadRecordings()
        }
    }
    

    
    private func generateTranscript(for recording: RecordingEntry) {
        guard !isGeneratingTranscript else { return }

        isGeneratingTranscript = true
        generatingTranscriptRecording = recording // Track which recording is being generated

        // Get the selected transcription engine
        let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.appleIntelligence.rawValue) ?? .appleIntelligence
        
        // Only request Apple Speech recognition permission for Apple Intelligence engine
        if selectedEngine == .appleIntelligence {
            SFSpeechRecognizer.requestAuthorization { authStatus in
                DispatchQueue.main.async {
                    switch authStatus {
                    case .authorized:
                        self.performEnhancedTranscription(for: recording)
                    case .denied, .restricted:
                        self.isGeneratingTranscript = false
                        self.generatingTranscriptRecording = nil
                    case .notDetermined:
                        self.isGeneratingTranscript = false
                        self.generatingTranscriptRecording = nil
                    @unknown default:
                        self.isGeneratingTranscript = false
                        self.generatingTranscriptRecording = nil
                    }
                }
            }
        } else {
            // For non-Apple engines (OpenAI, AWS, Whisper), skip Apple Speech permission
            self.performEnhancedTranscription(for: recording)
        }
    }
    
    private func performEnhancedTranscription(for recording: RecordingEntry) {
        // Progress is now shown inline on the button, no modal needed
        
        Task {
            // Use the selected transcription engine
            let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.appleIntelligence.rawValue) ?? .appleIntelligence
            
            do {
                // Get the absolute URL using the coordinator
                guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                    print("❌ Invalid recording URL: \(recording.recordingURL ?? "nil")")
                    throw NSError(domain: "Transcription", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid recording URL"])
                }
                
                // Start transcription job through BackgroundProcessingManager
                try await backgroundProcessingManager.startTranscriptionJob(
                    recordingURL: recordingURL,
                                            recordingName: recording.recordingName ?? "Unknown Recording",
                    engine: selectedEngine
                )
                
                print("✅ Transcription job started through BackgroundProcessingManager")
                
                // The job will be processed in the background and the UI will be updated
                // through the BackgroundProcessingManager's published properties
                
            } catch {
                print("❌ Failed to start transcription job: \(error)")
                
                // Fallback to direct transcription if background processing fails
                print("🔄 Falling back to direct transcription...")
                do {
                    // Get recording URL from the recording parameter
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                        print("❌ Invalid recording URL for fallback transcription")
                        return
                    }
                    
                    let result = try await enhancedTranscriptionManager.transcribeAudioFile(at: recordingURL, using: selectedEngine)
                    
                    print("📊 Transcription result: success=\(result.success), textLength=\(result.fullText.count)")
                    
                    if result.success && !result.fullText.isEmpty {
                        print("✅ Creating transcript data...")
                        // Create transcript data
                        let transcriptData = TranscriptData(
                            recordingURL: recordingURL,
                            recordingName: recording.recordingName ?? "Unknown Recording",
                            recordingDate: recording.recordingDate ?? Date(),
                            segments: result.segments
                        )
                        
                        // Save the transcript using Core Data
                        let appCoordinator = appCoordinator
                        guard let recordingId = transcriptData.recordingId else {
                            print("❌ Transcript data missing recording ID")
                            return
                        }
                        let transcriptId = appCoordinator.addTranscript(
                            for: recordingId,
                            segments: transcriptData.segments,
                            speakerMappings: transcriptData.speakerMappings,
                            engine: transcriptData.engine,
                            processingTime: transcriptData.processingTime,
                            confidence: transcriptData.confidence
                        )
                        if transcriptId != nil {
                            print("✅ Transcript saved to Core Data with ID: \(transcriptId!)")
                        } else {
                            print("❌ Failed to save transcript to Core Data")
                        }
                        print("💾 Transcript saved successfully")
                        
                                            // Don't automatically open the transcript view - let user choose when to edit
                        
                        // Force UI refresh to update button states
                        self.forceRefreshUI()
                    } else {
                        print("❌ Transcription failed or returned empty result")
                    }
                } catch {
                    print("❌ Fallback transcription also failed: \(error)")
                }
            }
            
            await MainActor.run {
                self.isGeneratingTranscript = false
                self.generatingTranscriptRecording = nil
                print("🏁 Transcription process completed")

                // Refresh the recordings list to show the new transcript
                self.loadRecordings()
            }
        }
    }
    
    private func setupTranscriptionCompletionCallback() {
        // Capture the transcription manager for the notification handler
        let transcriptionManager = enhancedTranscriptionManager
        
        // Set up notification listener for updating pending jobs when recordings are renamed
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UpdatePendingTranscriptionJobs"),
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let oldURL = userInfo["oldURL"] as? URL,
                  let newURL = userInfo["newURL"] as? URL,
                  let newName = userInfo["newName"] as? String else {
                return
            }
            
            Task { @MainActor in
                transcriptionManager.updatePendingJobsForRenamedRecording(
                    from: oldURL,
                    to: newURL,
                    newName: newName
                )
            }
        }
        
        // Set up completion handler for BackgroundProcessingManager
        backgroundProcessingManager.onTranscriptionCompleted = { transcriptData, job in
            Task { @MainActor in
                print("🎉 Background processing transcription completed for: \(job.recordingName)")
                
                // Find the recording that matches this transcription
                if let recording = recordings.first(where: { recording in
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording.recording) else {
                        return false
                    }
                    return recordingURL == job.recordingURL
                }) {
                    print("💾 Background transcript already saved by BackgroundProcessingManager")
                    
                    // Don't automatically open the transcript view - let user choose when to edit
                    
                    // Force UI refresh to update button states
                    self.forceRefreshUI()
                    
                    // Send notification for other views to refresh
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)
                    
                    // Show completion alert to notify user transcription finished in background
                    if !self.isShowingAlert {
                        self.completedTranscriptionText = "Transcription completed for: \(recording.recording.recordingName ?? "Unknown Recording")"
                        self.showingTranscriptionCompletionAlert = true
                    }
                } else {
                    print("❌ Could not find recording for completed transcription")
                }
            }
        }
        
        enhancedTranscriptionManager.onTranscriptionCompleted = { result, jobInfo in
            Task { @MainActor in
                
                print("🎉 Background transcription completed for: \(jobInfo.recordingName)")
                print("🔍 Looking for recording with URL: \(jobInfo.recordingURL)")
                print("📋 Available recordings: \(recordings.count)")
                for (index, recording) in recordings.enumerated() {
                    print("📋 Recording \(index): \(recording.recording.recordingName ?? "Unknown Recording") - \(recording.recording.recordingURL ?? "No URL")")
                }
                
                // Find the recording that matches this transcription
                if let recording = recordings.first(where: { recording in
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording.recording) else {
                        return false
                    }
                    return recordingURL == jobInfo.recordingURL
                }) {
                    // Create transcript data and save it
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording.recording) else {
                        print("❌ Invalid recording URL in completion handler")
                        return
                    }
                    
                    let transcriptData = TranscriptData(
                        recordingURL: recordingURL,
                        recordingName: recording.recording.recordingName ?? "Unknown Recording",
                        recordingDate: recording.recording.recordingDate ?? Date(),
                        segments: result.segments
                    )
                    
                    // Save transcript using Core Data
                    let appCoordinator = appCoordinator
                    guard let recordingId = transcriptData.recordingId else {
                        print("❌ Background transcript data missing recording ID")
                        return
                    }
                    let transcriptId = appCoordinator.addTranscript(
                        for: recordingId,
                        segments: transcriptData.segments,
                        speakerMappings: transcriptData.speakerMappings,
                        engine: transcriptData.engine,
                        processingTime: transcriptData.processingTime,
                        confidence: transcriptData.confidence
                    )
                    if transcriptId != nil {
                        print("✅ Background transcript saved to Core Data with ID: \(transcriptId!)")
                    } else {
                        print("❌ Failed to save background transcript to Core Data")
                    }
                    print("💾 Background transcript saved for: \(recording.recording.recordingName ?? "Unknown Recording")")
                    
                    // Force UI refresh to update button states
                    self.forceRefreshUI()
                    
                    // Send notification for other views to refresh
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)
                    
                    // Show completion alert to notify user transcription finished in background
                    if !self.isShowingAlert {
                        self.completedTranscriptionText = "Transcription completed for: \(recording.recording.recordingName ?? "Unknown Recording")"
                        self.showingTranscriptionCompletionAlert = true
                    }
                } else {
                    print("❌ No matching recording found for job: \(jobInfo.recordingName)")
                    print("❌ Job URL: \(jobInfo.recordingURL)")
                    print("❌ Available recording URLs:")
                    for recording in self.recordings {
                        print("❌   - \(recording.recording.recordingURL ?? "No URL")")
                    }
                }
            }
        }
    }
}

struct EditableTranscriptView: View {
    let recording: RecordingEntry
    let transcript: TranscriptData
    let transcriptManager: TranscriptManager
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var locationAddress: String?
    @State private var editedSegments: [TranscriptSegment]
    @State private var isRerunningTranscription = false
    @State private var showingRerunAlert = false
    @StateObject private var enhancedTranscriptionManager = EnhancedTranscriptionManager()
    @ObservedObject private var backgroundProcessingManager = BackgroundProcessingManager.shared
    
    init(recording: RecordingEntry, transcript: TranscriptData, transcriptManager: TranscriptManager) {
        self.recording = recording
        self.transcript = transcript
        self.transcriptManager = transcriptManager
        self._editedSegments = State(initialValue: transcript.segments)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                
                // Transcript Content
                ScrollView {
                    if editedSegments.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("No transcript content available")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Transcript segments: \(editedSegments.count)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(editedSegments.enumerated()), id: \.offset) { index, segment in
                                TranscriptSegmentView(segment: $editedSegments[index])
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .id("transcript-\(editedSegments.count)-\(editedSegments.first?.text.prefix(10).hashValue ?? 0)")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Rerun Transcription Button
                VStack(spacing: 12) {
                    Divider()
                        .padding(.horizontal, 16)
                    
                    Button(action: {
                        showingRerunAlert = true
                    }) {
                        HStack {
                            if isRerunningTranscription {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                                Text("Rerunning Transcription...")
                            } else {
                                Image(systemName: "arrow.clockwise")
                                Text("Rerun Transcription")
                            }
                        }
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isRerunningTranscription ? Color.orange : Color.blue)
                        .cornerRadius(10)
                    }
                    .disabled(isRerunningTranscription)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Edit Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveTranscript()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("Rerun Transcription", isPresented: $showingRerunAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Rerun", role: .destructive) {
                    rerunTranscription()
                }
            } message: {
                Text("This will replace the current transcript with a new transcription using the currently configured transcription service. This action cannot be undone.")
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionRerunCompleted"))) { notification in
                // Handle transcription rerun completion
                if let userInfo = notification.userInfo,
                   let notificationURL = userInfo["recordingURL"] as? URL,
                   let segments = userInfo["segments"] as? [TranscriptSegment],
                   let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                   notificationURL == recordingURL {
                    
                    print("🎉 Received transcription rerun completion notification")
                    
                    // Save the new transcript to Core Data first (this will replace the existing transcript)
                    saveNewTranscriptToCoreData(segments: segments)
                    
                    isRerunningTranscription = false
                    
                    print("✅ Transcript UI updated with rerun results from notification")
                    
                    // Force the parent view to refresh by posting a notification
                    NotificationCenter.default.post(name: NSNotification.Name("TranscriptReplacementCompleted"), object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TranscriptionCompleted"))) { _ in
                // Refresh transcript data from Core Data when transcription is completed
                refreshTranscriptFromCoreData()
            }
            .onAppear {
                // Always refresh transcript data when the view appears to ensure we have the latest content
                refreshTranscriptFromCoreData()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func saveTranscript() {
        // Note: Transcript updates are now handled through Core Data
        // This method is kept for potential future implementation
    }
    
    private func rerunTranscription() {
        print("🔄 Starting transcription rerun for: \(recording.recordingName ?? "Unknown Recording")")
        
        isRerunningTranscription = true
        
        Task {
            do {
                // Get the currently configured transcription engine
                let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.appleIntelligence.rawValue) ?? .appleIntelligence
                
                print("🔧 Using transcription engine: \(selectedEngine.rawValue)")
                
                // Get the absolute URL using the coordinator
                guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                    print("❌ Invalid recording URL: \(recording.recordingURL ?? "nil")")
                    await MainActor.run {
                        isRerunningTranscription = false
                    }
                    return
                }
                
                print("🎯 Rerunning transcription for file: \(recordingURL.lastPathComponent)")
                
                // Check current job status before starting
                print("🔍 Current job status check:")
                print("   - Active jobs count: \(backgroundProcessingManager.activeJobs.count)")
                print("   - Current job: \(backgroundProcessingManager.currentJob?.recordingName ?? "None")")
                print("   - Processing status: \(backgroundProcessingManager.processingStatus)")
                
                // Start transcription job through BackgroundProcessingManager
                try await backgroundProcessingManager.startTranscriptionJob(
                    recordingURL: recordingURL,
                    recordingName: recording.recordingName ?? "Unknown Recording",
                    engine: selectedEngine
                )
                
                print("✅ Transcription rerun job started through BackgroundProcessingManager")
                
                // Check job status after starting
                print("🔍 Job status after starting:")
                print("   - Active jobs count: \(backgroundProcessingManager.activeJobs.count)")
                print("   - Current job: \(backgroundProcessingManager.currentJob?.recordingName ?? "None")")
                print("   - Processing status: \(backgroundProcessingManager.processingStatus)")
                
                // Set up a one-time completion handler for this specific rerun
                setupRerunCompletionHandler(for: recordingURL)
                
            } catch {
                print("❌ Failed to start transcription rerun job: \(error)")
                
                // Fallback to direct transcription if background processing fails
                print("🔄 Falling back to direct transcription for rerun...")
                do {
                    guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                        print("❌ Invalid recording URL for fallback transcription rerun")
                        await MainActor.run {
                            isRerunningTranscription = false
                        }
                        return
                    }
                    
                    // Get the currently configured transcription engine
                    let selectedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.appleIntelligence.rawValue) ?? .appleIntelligence
                    
                    let result = try await enhancedTranscriptionManager.transcribeAudioFile(at: recordingURL, using: selectedEngine)
                    
                    print("📊 Transcription rerun result: success=\(result.success), textLength=\(result.fullText.count)")
                    
                    if result.success && !result.fullText.isEmpty {
                        await MainActor.run {
                            // Save the new transcript to Core Data first (this will replace the existing transcript)
                            saveNewTranscriptToCoreData(segments: result.segments)
                            
                            print("✅ Transcript UI updated with rerun results")
                            
                            // Force the parent view to refresh by posting a notification
                            NotificationCenter.default.post(name: NSNotification.Name("TranscriptReplacementCompleted"), object: nil)
                        }
                    } else {
                        print("❌ Transcription rerun failed or returned empty result")
                    }
                } catch {
                    print("❌ Fallback transcription rerun also failed: \(error)")
                }
                
                await MainActor.run {
                    isRerunningTranscription = false
                }
            }
        }
    }
    
    private func setupRerunCompletionHandler(for recordingURL: URL) {
        // Set up a temporary completion handler for the background processing manager
        let originalHandler = backgroundProcessingManager.onTranscriptionCompleted
        
        backgroundProcessingManager.onTranscriptionCompleted = { transcriptData, job in
            // Only handle completion for our specific recording
            if job.recordingURL == recordingURL {
                Task { @MainActor in
                    print("🎉 Background processing transcription rerun completed for: \(job.recordingName)")
                    
                    // Save the new transcript to Core Data and post notification
                    print("💾 Saving rerun transcript to Core Data...")
                    
                    // Post notification with the new segments
                    NotificationCenter.default.post(
                        name: NSNotification.Name("TranscriptionRerunCompleted"),
                        object: nil,
                        userInfo: [
                            "recordingURL": recordingURL,
                            "segments": transcriptData.segments
                        ]
                    )
                    
                    print("✅ Posted transcription rerun completion notification")
                    
                    // Restore the original handler
                    BackgroundProcessingManager.shared.onTranscriptionCompleted = originalHandler
                }
            } else {
                // If it's not our recording, call the original handler
                originalHandler?(transcriptData, job)
            }
        }
    }
    
    private func saveNewTranscriptToCoreData(segments: [TranscriptSegment]) {
        print("💾 Saving new transcript to Core Data...")
        
        // We need to find and update the existing transcript in Core Data
        guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
            print("❌ Invalid recording URL for Core Data save")
            return
        }
        
        // Use the app coordinator from environment
        let coordinator = appCoordinator
        
        // Find the recording entry
        if let recordingEntry = coordinator.getRecording(url: recordingURL),
           let recordingId = recordingEntry.id {
            
            // For rerun transcriptions, we'll replace the existing transcript
            // The Core Data system will update the existing transcript instead of creating a new one
            print("🔄 Replacing transcript for recording ID: \(recordingId)")
            
            // Get the selected transcription engine
            let engineString = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? "appleIntelligence"
            let engine = TranscriptionEngine(rawValue: engineString) ?? .appleIntelligence
            
            
            // Add the new transcript
            let transcriptId = coordinator.addTranscript(
                for: recordingId,
                segments: segments,
                speakerMappings: [:], // No speaker mappings needed
                engine: engine,
                processingTime: 0.0, // We don't track this in reruns
                confidence: 1.0
            )
            
            if transcriptId != nil {
                print("✅ Transcript replaced in Core Data with ID: \(transcriptId!)")
                
                // Immediately refresh the UI with the updated transcript data
                refreshTranscriptFromCoreData()
                
                // Post notification to refresh the main transcripts view
                NotificationCenter.default.post(name: NSNotification.Name("TranscriptionCompleted"), object: nil)
            } else {
                print("❌ Failed to replace transcript in Core Data")
            }
        } else {
            print("❌ Could not find recording entry in Core Data for transcript save")
        }
    }
    
    private func refreshTranscriptFromCoreData() {
        guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
            return
        }
        
        // Force Core Data context to refresh its cache
        appCoordinator.coreDataManager.refreshContext()
        
        // Get the updated transcript data from Core Data
        if let recordingEntry = appCoordinator.getRecording(url: recordingURL),
           let recordingId = recordingEntry.id,
           let updatedTranscript = appCoordinator.getTranscriptData(for: recordingId) {
            
            // Only update if we have segments with actual content
            let hasValidContent = updatedTranscript.segments.contains { !$0.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }
            
            guard hasValidContent else { return }
            
            // Force SwiftUI to detect the change by clearing first, then setting
            editedSegments = []
            
            // Small delay to ensure UI updates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.editedSegments = updatedTranscript.segments
            }
        }
    }
}

struct TranscriptSegmentView: View {
    @Binding var segment: TranscriptSegment
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(formatTime(segment.startTime))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .cornerRadius(6)
                
                Spacer()
            }
            
            TextEditor(text: Binding(
                get: { segment.text },
                set: { segment = TranscriptSegment(speaker: segment.speaker, text: $0, startTime: segment.startTime, endTime: segment.endTime) }
            ))
            .font(.body)
            .frame(minHeight: max(120, calculateTextHeight(for: segment.text)))
            .padding(12)
            .background(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.systemGray4), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color(.systemGray6).opacity(0.3))
        .cornerRadius(12)
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func calculateTextHeight(for text: String) -> CGFloat {
        // More accurate height calculation
        let lineHeight: CGFloat = 22 // Body font line height
        let charactersPerLine: CGFloat = 60 // Characters per line (adjusted for wider view)
        
        // Count explicit line breaks
        let explicitLines = CGFloat(text.components(separatedBy: "\n").count)
        
        // Estimate wrapped lines
        let wrappedLines = max(1, ceil(CGFloat(text.count) / charactersPerLine))
        
        // Use the larger of the two estimates
        let totalLines = max(explicitLines, wrappedLines)
        
        // Calculate height with padding
        let calculatedHeight = totalLines * lineHeight + 24 // 24pt for padding
        
        // Ensure reasonable bounds
        return max(120, min(calculatedHeight, 400))
    }
}


struct TranscriptDetailView: View {
    let recording: RecordingEntry
    let transcriptText: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var locationAddress: String?
    
    var body: some View {
        NavigationView {
            VStack {
                if transcriptText.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Generating transcript...")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(recording.recordingName ?? "Unknown Recording")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text(UserPreferences.shared.formatMediumDateTime(recording.recordingDate ?? Date()))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                               let locationData = TranscriptsView.loadLocationDataForRecording(url: recordingURL) {
                                HStack {
                                    Image(systemName: "location.fill")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Text(locationAddress ?? locationData.coordinateString)
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            
                            Divider()
                            
                            Text(transcriptText)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineSpacing(4)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let recordingURL = appCoordinator.getAbsoluteURL(for: recording),
                   let locationData = TranscriptsView.loadLocationDataForRecording(url: recordingURL) {
                    let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
                    let tempLocationManager = LocationManager()
                    tempLocationManager.reverseGeocodeLocation(location) { address in
                        if let address = address {
                            locationAddress = address
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Title Row View

struct TitleRowView: View {
    let title: TitleItem
    let recordingName: String
    @StateObject private var systemIntegration = SystemIntegrationManager()
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Category icon
            Image(systemName: title.category.icon)
                .font(.caption)
                .foregroundColor(.accentColor)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 4) {
                // Title text
                Text(title.text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                
                // Confidence indicator
                HStack {
                    Text("Confidence: \(safeConfidencePercent(title.confidence))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // Copy button
                    Button(action: {
                        UIPasteboard.general.string = title.text
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Enhanced Title Row View

struct EnhancedTitleRowView: View {
    let title: TitleItem
    let recordingName: String
    @StateObject private var systemIntegration = SystemIntegrationManager()
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Category icon with background
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 32, height: 32)
                
                Image(systemName: title.category.icon)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                // Title text
                Text(title.text)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                
                // Metadata row
                HStack {
                    // Confidence indicator
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                            .font(.caption2)
                            .foregroundColor(confidenceColor)
                        Text("\(safeConfidencePercent(title.confidence))%")
                            .font(.caption2)
                            .foregroundColor(confidenceColor)
                    }
                    
                    // Category badge
                    Text(title.category.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                    
                    Spacer()
                    
                    // Copy button
                    Button(action: {
                        UIPasteboard.general.string = title.text
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
    
    private var confidenceColor: Color {
        guard title.confidence.isFinite else { return .gray }
        switch title.confidence {
        case 0.8...1.0: return .green
        case 0.6..<0.8: return .blue
        case 0.4..<0.6: return .orange
        default: return .red
        }
    }
}

// MARK: - Helper Functions

private func safeConfidencePercent(_ confidence: Double) -> Int {
    guard confidence.isFinite else { return 0 }
    return Int(confidence * 100)
}