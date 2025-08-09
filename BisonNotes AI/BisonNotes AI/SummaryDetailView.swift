import SwiftUI
import MapKit
import CoreLocation

struct SummaryDetailView: View {
    let recording: RecordingFile
    @State private var summaryData: EnhancedSummaryData
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var locationAddress: String?
    @State private var expandedSections: Set<String> = ["summary"]
    @State private var isRegenerating = false
    @State private var showingRegenerationAlert = false
    @State private var regenerationError: String?
    @State private var showingDeleteConfirmation = false
    @State private var showingLocationDetail = false
    @State private var showingTitleSelector = false
    @State private var editingTitle: TitleItem?
    @State private var customTitleText = ""
    @State private var isUpdatingRecordingName = false
    @State private var showingDateEditor = false
    @State private var editingDate = Date()
    @State private var editingTime = Date()
    @State private var isUpdatingDate = false
    @State private var showingLocationPicker = false
    @State private var isUpdatingLocation = false
    
    init(recording: RecordingFile, summaryData: EnhancedSummaryData) {
        self.recording = recording
        self._summaryData = State(initialValue: summaryData)
    }
    
    var body: some View {
        NavigationView {
            content
                .navigationTitle("Enhanced Summary")
                .navigationBarTitleDisplayMode(.inline)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
    
    private var content: some View {
        VStack(spacing: 0) {
            // Location Section - Shows map or add location option
            locationSection
            
            // Enhanced Summary Content
            ScrollView([.vertical], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    // Header Section
                    headerSection
                    
                    // Summary Section (Expandable)
                    summarySection
                    
                    // Tasks Section (Expandable)
                    tasksSection
                    
                    // Reminders Section (Expandable)
                    remindersSection
                    
                    // Titles Section (Expandable)
                    titlesSection
                    
                    // Date/Time Editor Section
                    dateTimeEditorSection
                    
                    // Metadata Section (Expandable, moved to bottom)
                    metadataSection
                    
                    // Regenerate Button Section
                    regenerateSection
                }
                .padding(.vertical)
            }
        }
        .onAppear {
            // Debug location data availability
            if let locationData = recording.locationData {
                print("📍 SummaryDetailView: Recording has location data - lat: \(locationData.latitude), lon: \(locationData.longitude)")
            } else {
                print("📍 SummaryDetailView: Recording has NO location data")
            }
            
            // Refresh summary data from coordinator to get the latest version
            if let recordingEntry = appCoordinator.getRecording(url: recording.url),
               let recordingId = recordingEntry.id,
        let completeData = appCoordinator.getCompleteRecordingData(id: recordingId),
               let latestSummary = completeData.summary {
                summaryData = latestSummary
            }
            
            if let locationData = recording.locationData {
                let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
                let tempLocationManager = LocationManager()
                tempLocationManager.reverseGeocodeLocation(location) { address in
                    if let address = address {
                        locationAddress = address
                    }
                }
            }
        }
        .alert("Regeneration Error", isPresented: $showingRegenerationAlert) {
            Button("OK") {
                regenerationError = nil
            }
        } message: {
            if let error = regenerationError {
                Text(error)
            }
        }
        .alert("Delete Summary", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSummary()
            }
        } message: {
            Text("Are you sure you want to delete this summary? This action cannot be undone. The audio file and transcript will remain unchanged.")
        }
        .sheet(isPresented: $showingLocationDetail) {
            if let locationData = recording.locationData {
                LocationDetailView(locationData: locationData)
            }
        }
        .sheet(isPresented: $showingLocationPicker) {
            LocationPickerView(
                onLocationSelected: { location in
                    updateRecordingLocation(location)
                }
            )
        }
    }
    
    // MARK: - Location Section
    
    private var locationSection: some View {
        Group {
            if let locationData = recording.locationData {
                // Existing location - show map
                VStack(spacing: 0) {
                    Map(position: .constant(.region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005) // Tighter zoom like Apple
                    )))) {
                        Marker("Recording Location", coordinate: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude))
                            .foregroundStyle(.orange) // More prominent color
                    }
                    .frame(height: 250) // Taller like Apple's design
                    .clipShape(RoundedRectangle(cornerRadius: 0)) // No rounded corners for full-width effect
                    .disabled(true) // Make map static and non-interactive
                    .allowsHitTesting(false) // Prevent all touch interactions
                    
                    // Location info bar below map
                    HStack {
                        Image(systemName: "location.fill")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            if let address = locationAddress, !address.isEmpty {
                                Text(address)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                            } else {
                                Text("Recording Location")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                            }
                            
                            Text(locationData.coordinateString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Edit location button
                        Button(action: {
                            showingLocationPicker = true
                        }) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                                .foregroundColor(.green)
                        }
                        .disabled(isUpdatingLocation)
                        
                        // Button to open full map view
                        Button(action: {
                            showingLocationDetail = true
                        }) {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6))
                }
            } else {
                // No location - show add location option
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "location.slash")
                            .font(.title2)
                            .foregroundColor(.gray)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Location Set")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            Text("Add a location to remember where this recording was made")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        
                        Spacer()
                    }
                    
                    Button(action: {
                        showingLocationPicker = true
                    }) {
                        HStack {
                            if isUpdatingLocation {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "location.badge.plus")
                            }
                            Text(isUpdatingLocation ? "Adding..." : "Add Location")
                        }
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(isUpdatingLocation ? Color.gray : Color.blue)
                        .cornerRadius(8)
                    }
                    .disabled(isUpdatingLocation)
                }
                .padding()
                .background(Color(.systemGray6).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Recording name
            Text(recording.name)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            // Prominent date/time display
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "calendar.circle.fill")
                        .font(.title3)
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording Date & Time")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fontWeight(.medium)
                        
                        Text(formatFullDateTime(summaryData.recordingDate))
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    // Custom date indicator (we'll implement this later)
                    if isCustomDate {
                        Text("Custom")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(.systemGray6).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            // Duration info
            HStack {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Duration: \(recording.durationString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Metadata Section
    
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("Metadata")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            
            VStack(alignment: .leading, spacing: 12) {
                metadataRow(title: "AI Method", value: summaryData.aiMethod, icon: "brain.head.profile")
                metadataRow(title: "Generation Time", value: formatDate(summaryData.generatedAt), icon: "clock.arrow.circlepath")
                metadataRow(title: "Content Type", value: summaryData.contentType.rawValue, icon: "doc.text")
                metadataRow(title: "Word Count", value: "\(summaryData.wordCount) words", icon: "text.word.spacing")
                metadataRow(title: "Compression Ratio", value: summaryData.formattedCompressionRatio, icon: "chart.bar.fill")
                metadataRow(title: "Processing Time", value: summaryData.formattedProcessingTime, icon: "timer")
                metadataRow(title: "Quality", value: summaryData.qualityDescription, icon: "star.fill", valueColor: qualityColor)
                metadataRow(title: "Confidence", value: "\(Int(summaryData.confidence * 100))%", icon: "checkmark.shield.fill", valueColor: confidenceColor)
            }
        }
        .onTapGesture {
            toggleSection("metadata")
        }
    }
    
    private func metadataRow(title: String, value: String, icon: String, valueColor: Color = .primary) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.caption)
                .foregroundColor(valueColor)
                .fontWeight(.medium)
        }
    }
    
    private var qualityColor: Color {
        switch summaryData.qualityDescription {
        case "High Quality": return .green
        case "Good Quality": return .blue
        case "Fair Quality": return .orange
        default: return .red
        }
    }
    
    private var confidenceColor: Color {
        switch summaryData.confidence {
        case 0.8...1.0: return .green
        case 0.6..<0.8: return .blue
        case 0.4..<0.6: return .orange
        default: return .red
        }
    }
    
    // MARK: - Summary Section
    
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.quote")
                    .foregroundColor(.accentColor)
                Text("Summary")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            
            AITextView(text: summaryData.summary, aiService: AIService.from(aiMethod: summaryData.aiMethod))
                .font(.body)
                .lineSpacing(4)
                .padding(.top, 4)
                .textSelection(.enabled)
        }
        .onTapGesture {
            toggleSection("summary")
        }
    }
    
    // MARK: - Tasks Section
    
    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundColor(.green)
                Text("Tasks")
                    .font(.headline)
                if summaryData.tasks.count > 0 {
                    Text("(\(summaryData.tasks.count))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 8)
            
            if summaryData.tasks.isEmpty {
                emptyStateView(message: "No tasks found", icon: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(summaryData.tasks, id: \.id) { task in
                        EnhancedTaskRowView(task: task, recordingName: summaryData.recordingName)
                    }
                }
                .padding(.top, 4)
            }
        }
        .onTapGesture {
            toggleSection("tasks")
        }
    }
    
    // MARK: - Reminders Section
    
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bell")
                    .foregroundColor(.orange)
                Text("Reminders")
                    .font(.headline)
                if summaryData.reminders.count > 0 {
                    Text("(\(summaryData.reminders.count))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 8)
            
            if summaryData.reminders.isEmpty {
                emptyStateView(message: "No reminders found", icon: "bell.slash")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(summaryData.reminders, id: \.id) { reminder in
                        EnhancedReminderRowView(reminder: reminder, recordingName: summaryData.recordingName)
                    }
                }
                .padding(.top, 4)
            }
        }
        .onTapGesture {
            toggleSection("reminders")
        }
    }
    
    // MARK: - Titles Section
    
    private var titlesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.quote")
                    .foregroundColor(Color.purple)
                Text("Titles")
                    .font(.headline)
                if summaryData.titles.count > 0 {
                    Text("(\(summaryData.titles.count))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                // Button to show title selector
                Button(action: {
                    showingTitleSelector = true
                }) {
                    Text("Change Title")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(isUpdatingRecordingName)
            }
            .padding(.bottom, 8)
            
            // Current recording name display
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Title")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text(summaryData.recordingName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    if isUpdatingRecordingName {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            
            if summaryData.titles.isEmpty {
                emptyStateView(message: "No alternative titles found", icon: "text.quote")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alternative Titles")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summaryData.titles, id: \.id) { title in
                            SelectableTitleRowView(
                                title: title, 
                                isCurrentTitle: title.text == summaryData.recordingName,
                                onSelect: { selectedTitle in
                                    updateRecordingName(to: selectedTitle.text)
                                },
                                onEdit: { titleToEdit in
                                    editingTitle = titleToEdit
                                    customTitleText = titleToEdit.text
                                }
                            )
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onTapGesture {
            toggleSection("titles")
        }
        .sheet(isPresented: $showingTitleSelector) {
            TitleSelectorView(
                titles: summaryData.titles,
                currentTitle: summaryData.recordingName,
                onTitleSelected: { newTitle in
                    updateRecordingName(to: newTitle)
                },
                onCustomTitle: { customTitle in
                    updateRecordingName(to: customTitle)
                }
            )
        }
        .alert("Edit Title", isPresented: Binding(
            get: { editingTitle != nil },
            set: { if !$0 { editingTitle = nil } }
        )) {
            TextField("Title", text: $customTitleText)
            Button("Cancel") { editingTitle = nil }
            Button("Use This Title") {
                updateRecordingName(to: customTitleText)
                editingTitle = nil
            }
        }
    }
    
    // MARK: - Date/Time Editor Section
    
    private var dateTimeEditorSection: some View {
        VStack(spacing: 16) {
            Divider()
                .padding(.horizontal)
            
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundColor(.blue)
                    Text("Recording Date & Time")
                        .font(.headline)
                    Spacer()
                }
                
                Text("Set a custom date and time for this recording")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Button(action: {
                    // Initialize the editing dates with current recording date
                    editingDate = summaryData.recordingDate
                    editingTime = summaryData.recordingDate
                    showingDateEditor = true
                }) {
                    HStack {
                        if isUpdatingDate {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "calendar.badge.plus")
                        }
                        Text(isUpdatingDate ? "Updating..." : "Set Custom Date & Time")
                    }
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(isUpdatingDate ? Color.gray : Color.blue)
                    .cornerRadius(10)
                }
                .disabled(isUpdatingDate)
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showingDateEditor) {
            DateTimeEditorView(
                currentDate: summaryData.recordingDate,
                onDateTimeSelected: { newDateTime in
                    updateRecordingDateTime(to: newDateTime)
                }
            )
        }
    }
    
    // MARK: - Regenerate Section
    
    private var regenerateSection: some View {
        VStack(spacing: 16) {
            Divider()
                .padding(.horizontal)
            
            VStack(spacing: 12) {
                Text("Need a different summary?")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Regenerate this summary with the current AI engine settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Button(action: {
                    Task {
                        await regenerateSummary()
                    }
                }) {
                    HStack {
                        if isRegenerating {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRegenerating ? "Regenerating..." : "Regenerate Summary")
                    }
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(isRegenerating ? Color.gray : Color.orange)
                    .cornerRadius(10)
                }
                .disabled(isRegenerating)
            }
            .padding(.horizontal)
            
            // Location Editor Section
            locationEditorSection
            
            // Delete Section
            deleteSection
        }
    }
    
    // MARK: - Location Editor Section
    
    private var locationEditorSection: some View {
        VStack(spacing: 16) {
            Divider()
                .padding(.horizontal)
            
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "location.badge.plus")
                        .foregroundColor(.green)
                    Text("Recording Location")
                        .font(.headline)
                    Spacer()
                }
                
                if let locationData = recording.locationData {
                    // Show current location with edit option
                    VStack(spacing: 8) {
                        Text("Current location set")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if let address = locationAddress, !address.isEmpty {
                            Text(address)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("Location: \(locationData.coordinateString)")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                        }
                        
                        Button(action: {
                            showingLocationPicker = true
                        }) {
                            HStack {
                                if isUpdatingLocation {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "pencil.circle")
                                }
                                Text(isUpdatingLocation ? "Updating..." : "Edit Location")
                            }
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(isUpdatingLocation ? Color.gray : Color.green)
                            .cornerRadius(10)
                        }
                        .disabled(isUpdatingLocation)
                    }
                } else {
                    // Show add location option
                    VStack(spacing: 8) {
                        Text("No location set for this recording")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: {
                            showingLocationPicker = true
                        }) {
                            HStack {
                                if isUpdatingLocation {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "location.badge.plus")
                                }
                                Text(isUpdatingLocation ? "Adding..." : "Add Location")
                            }
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(isUpdatingLocation ? Color.gray : Color.green)
                            .cornerRadius(10)
                        }
                        .disabled(isUpdatingLocation)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
    
    // MARK: - Delete Section
    
    private var deleteSection: some View {
        VStack(spacing: 12) {
            Divider()
                .padding(.horizontal)
            
            VStack(spacing: 8) {
                Text("Delete Summary")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Remove this summary while keeping the audio file and transcript")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Button(action: {
                    showingDeleteConfirmation = true
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .cornerRadius(10)
                }
            }
            .padding(.horizontal)
        }
    }
    
    // MARK: - Delete Logic
    
    private func deleteSummary() {
        print("🗑️ Deleting summary for: \(summaryData.recordingName)")
        print("🆔 Summary ID: \(summaryData.id)")
        
        do {
            // Delete the summary from Core Data
            try appCoordinator.coreDataManager.deleteSummary(id: summaryData.id)
            print("✅ Summary deleted from Core Data")
            
            // Update the recording to remove summary reference (if recording still exists)
            if let recordingId = summaryData.recordingId,
               let recording = appCoordinator.getRecording(id: recordingId) {
                recording.summaryId = nil
                recording.summaryStatus = ProcessingStatus.notStarted.rawValue
                recording.lastModified = Date()
                
                // Save the updated recording
                do {
                    try appCoordinator.coreDataManager.saveContext()
                    print("✅ Recording updated to remove summary reference")
                } catch {
                    print("❌ Failed to update recording: \(error)")
                }
            } else {
                print("ℹ️ Recording no longer exists (orphaned summary) - skipping recording update")
            }
            
            // Notify parent views to refresh
            NotificationCenter.default.post(name: NSNotification.Name("SummaryDeleted"), object: nil)
            appCoordinator.objectWillChange.send()
            
            print("✅ Summary deletion completed")
            dismiss()
            
        } catch {
            print("❌ Failed to delete summary: \(error)")
            regenerationError = "Failed to delete summary: \(error.localizedDescription)"
            showingRegenerationAlert = true
        }
    }
    
    // MARK: - Regeneration Logic
    
    private func regenerateSummary() async {
        guard !isRegenerating else { return }
        
        await MainActor.run {
            isRegenerating = true
        }
        
        do {
            // Get the recording data
            guard let recordingId = summaryData.recordingId,
                  let recordingData = appCoordinator.getCompleteRecordingData(id: recordingId) else {
                throw NSError(domain: "SummaryRegeneration", code: 2, userInfo: [NSLocalizedDescriptionKey: "No recording data found"])
            }
            
            // Get the transcript
            guard let transcript = recordingData.transcript else {
                throw NSError(domain: "SummaryRegeneration", code: 3, userInfo: [NSLocalizedDescriptionKey: "No transcript found for this recording"])
            }
            
            print("🔄 Starting summary regeneration for: \(summaryData.recordingName)")
            print("📝 Transcript length: \(transcript.plainText.count) characters")
            print("🤖 Current AI method: \(summaryData.aiMethod)")
            
            // Generate new summary using the current AI engine
            let newEnhancedSummary = try await SummaryManager.shared.generateEnhancedSummary(
                from: transcript.plainText,
                for: summaryData.recordingURL,
                recordingName: summaryData.recordingName,
                recordingDate: summaryData.recordingDate
            )
            
            print("✅ New summary generated successfully")
            print("📄 New summary length: \(newEnhancedSummary.summary.count) characters")
            print("📋 New tasks: \(newEnhancedSummary.tasks.count)")
            print("📋 New reminders: \(newEnhancedSummary.reminders.count)")
            print("📋 New titles: \(newEnhancedSummary.titles.count)")
            
            // Delete the old summary from Core Data
            try appCoordinator.coreDataManager.deleteSummary(id: summaryData.id)
            print("🗑️ Deleted old summary with ID: \(summaryData.id)")
            
            // Debug: Check if recording name changed during regeneration
            print("🔍 SummaryDetailView regeneration name check:")
            print("   Old name: '\(summaryData.recordingName)'")
            print("   New name: '\(newEnhancedSummary.recordingName)'")
            print("   Names equal: \(newEnhancedSummary.recordingName == summaryData.recordingName)")
            
            // Update the recording name if it changed during regeneration
            if newEnhancedSummary.recordingName != summaryData.recordingName {
                print("📝 SummaryDetailView: Recording name updated from '\(summaryData.recordingName)' to '\(newEnhancedSummary.recordingName)'")
                // Update recording name in Core Data
                try appCoordinator.coreDataManager.updateRecordingName(
                    for: recordingId,
                    newName: newEnhancedSummary.recordingName
                )
            } else {
                print("⚠️ SummaryDetailView: Recording name did not change during regeneration")
            }
            
            // Create new summary entry in Core Data
            let newSummaryId = appCoordinator.workflowManager.createSummary(
                for: recordingId,
                transcriptId: summaryData.transcriptId ?? UUID(),
                summary: newEnhancedSummary.summary,
                tasks: newEnhancedSummary.tasks,
                reminders: newEnhancedSummary.reminders,
                titles: newEnhancedSummary.titles,
                contentType: newEnhancedSummary.contentType,
                aiMethod: newEnhancedSummary.aiMethod,
                originalLength: newEnhancedSummary.originalLength,
                processingTime: newEnhancedSummary.processingTime
            )
            
            if newSummaryId != nil {
                print("✅ New summary saved to Core Data with ID: \(newSummaryId?.uuidString ?? "nil")")
                
                await MainActor.run {
                    isRegenerating = false
                    // Dismiss the view to refresh the data
                    dismiss()
                }
            } else {
                throw NSError(domain: "SummaryRegeneration", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to save new summary to Core Data"])
            }
            
        } catch {
            print("❌ Summary regeneration failed: \(error)")
            await MainActor.run {
                regenerationError = "Failed to regenerate summary: \(error.localizedDescription)"
                showingRegenerationAlert = true
                isRegenerating = false
            }
        }
    }
    
    // MARK: - Helper Views
    
    private func emptyStateView(message: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.secondary)
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .italic()
        }
        .padding(.top, 4)
    }
    
    private func toggleSection(_ section: String) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        return UserPreferences.shared.formatShortDateTime(date)
    }
    
    private func safeConfidencePercent(_ confidence: Double) -> Int {
        guard confidence.isFinite else { return 0 }
        return Int(confidence * 100)
    }
    
    private func formatFullDateTime(_ date: Date) -> String {
        return UserPreferences.shared.formatFullDateTime(date)
    }
    
    // TODO: Implement custom date detection once Core Data field is added
    private var isCustomDate: Bool {
        // For now, return false. This will be implemented when we add dateSource to Core Data
        return false
    }
    
    // MARK: - Title Management
    
    private func updateRecordingName(to newName: String) {
        guard !isUpdatingRecordingName,
              let recordingId = summaryData.recordingId,
              newName != summaryData.recordingName,
              !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        isUpdatingRecordingName = true
        
        Task {
            do {
                // Update the recording name in Core Data
                try appCoordinator.coreDataManager.updateRecordingName(
                    for: recordingId,
                    newName: newName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                await MainActor.run {
                    // Update local state
                    let updatedSummaryData = EnhancedSummaryData(
                        id: summaryData.id,
                        recordingId: summaryData.recordingId ?? recordingId,
                        transcriptId: summaryData.transcriptId,
                        recordingURL: summaryData.recordingURL,
                        recordingName: newName.trimmingCharacters(in: .whitespacesAndNewlines),
                        recordingDate: summaryData.recordingDate,
                        summary: summaryData.summary,
                        tasks: summaryData.tasks,
                        reminders: summaryData.reminders,
                        titles: summaryData.titles,
                        contentType: summaryData.contentType,
                        aiMethod: summaryData.aiMethod,
                        originalLength: summaryData.originalLength,
                        processingTime: summaryData.processingTime,
                        generatedAt: summaryData.generatedAt,
                        version: summaryData.version,
                        wordCount: summaryData.wordCount,
                        compressionRatio: summaryData.compressionRatio,
                        confidence: summaryData.confidence
                    )
                    
                    summaryData = updatedSummaryData
                    isUpdatingRecordingName = false
                    
                    // Post notification to refresh other views
                    NotificationCenter.default.post(
                        name: NSNotification.Name("RecordingRenamed"),
                        object: nil,
                        userInfo: ["recordingId": recordingId, "newName": newName]
                    )
                    
                    print("✅ Successfully updated recording name to: '\(newName)'")
                }
            } catch {
                await MainActor.run {
                    isUpdatingRecordingName = false
                    regenerationError = "Failed to update title: \(error.localizedDescription)"
                    showingRegenerationAlert = true
                }
                print("❌ Failed to update recording name: \(error)")
            }
        }
    }
    
    // MARK: - Date/Time Management
    
    private func updateRecordingDateTime(to newDateTime: Date) {
        guard !isUpdatingDate,
              let recordingId = summaryData.recordingId,
              newDateTime != summaryData.recordingDate else {
            return
        }
        
        isUpdatingDate = true
        
        Task {
            do {
                // Update the recording date in Core Data
                try await updateRecordingDateInCoreData(recordingId: recordingId, newDate: newDateTime)
                
                await MainActor.run {
                    // Update local state
                    let updatedSummaryData = EnhancedSummaryData(
                        id: summaryData.id,
                        recordingId: summaryData.recordingId ?? recordingId,
                        transcriptId: summaryData.transcriptId,
                        recordingURL: summaryData.recordingURL,
                        recordingName: summaryData.recordingName,
                        recordingDate: newDateTime, // Updated date
                        summary: summaryData.summary,
                        tasks: summaryData.tasks,
                        reminders: summaryData.reminders,
                        titles: summaryData.titles,
                        contentType: summaryData.contentType,
                        aiMethod: summaryData.aiMethod,
                        originalLength: summaryData.originalLength,
                        processingTime: summaryData.processingTime,
                        generatedAt: summaryData.generatedAt,
                        version: summaryData.version,
                        wordCount: summaryData.wordCount,
                        compressionRatio: summaryData.compressionRatio,
                        confidence: summaryData.confidence
                    )
                    
                    summaryData = updatedSummaryData
                    isUpdatingDate = false
                    
                    // Post notification to refresh other views
                    NotificationCenter.default.post(
                        name: NSNotification.Name("RecordingDateUpdated"),
                        object: nil,
                        userInfo: ["recordingId": recordingId, "newDate": newDateTime]
                    )
                    
                    print("✅ Successfully updated recording date to: \(formatFullDateTime(newDateTime))")
                }
            } catch {
                await MainActor.run {
                    isUpdatingDate = false
                    regenerationError = "Failed to update date: \(error.localizedDescription)"
                    showingRegenerationAlert = true
                }
                print("❌ Failed to update recording date: \(error)")
            }
        }
    }
    
    private func updateRecordingDateInCoreData(recordingId: UUID, newDate: Date) async throws {
        // For now, we'll use a simple approach - later we'll add the dateSource field
        guard let recording = appCoordinator.getRecording(id: recordingId) else {
            throw NSError(domain: "CoreDataManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Recording not found"])
        }
        
        recording.recordingDate = newDate
        recording.lastModified = Date()
        
        try appCoordinator.coreDataManager.saveContext()
    }
    
    // MARK: - Location Management
    
    private func updateRecordingLocation(_ locationData: LocationData) {
        guard !isUpdatingLocation,
              let recordingId = summaryData.recordingId else {
            return
        }
        
        isUpdatingLocation = true
        
        Task {
            do {
                // Update the recording location in Core Data
                try await updateRecordingLocationInCoreData(recordingId: recordingId, locationData: locationData)
                
                await MainActor.run {
                    isUpdatingLocation = false
                    
                    // Post notification to refresh other views
                    NotificationCenter.default.post(
                        name: NSNotification.Name("RecordingLocationUpdated"),
                        object: nil,
                        userInfo: ["recordingId": recordingId, "location": locationData]
                    )
                    
                    print("✅ Successfully added location: \(locationData.displayLocation)")
                }
            } catch {
                await MainActor.run {
                    isUpdatingLocation = false
                    regenerationError = "Failed to add location: \(error.localizedDescription)"
                    showingRegenerationAlert = true
                }
                print("❌ Failed to update recording location: \(error)")
            }
        }
    }
    
    private func updateRecordingLocationInCoreData(recordingId: UUID, locationData: LocationData) async throws {
        guard let recording = appCoordinator.getRecording(id: recordingId) else {
            throw NSError(domain: "CoreDataManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Recording not found"])
        }
        
        // Update location fields
        recording.locationLatitude = locationData.latitude
        recording.locationLongitude = locationData.longitude
        recording.locationTimestamp = locationData.timestamp
        recording.locationAccuracy = locationData.accuracy ?? 0.0
        recording.locationAddress = locationData.address
        recording.lastModified = Date()
        
        try appCoordinator.coreDataManager.saveContext()
    }
}

// MARK: - Enhanced Task Row Component

struct EnhancedTaskRowView: View {
    let task: TaskItem
    let recordingName: String
    @StateObject private var integrationManager = SystemIntegrationManager()
    @State private var showingIntegrationSelection = false
    @State private var showingSuccessAlert = false
    @State private var showingErrorAlert = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Priority indicator
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            // Task content
            VStack(alignment: .leading, spacing: 4) {
                Text(task.text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(nil)
                
                // Task metadata
                HStack {
                    Image(systemName: task.category.icon)
                        .font(.caption2)
                        .foregroundColor(categoryColor)
                    
                    Text(task.category.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if let timeRef = task.timeReference {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text(timeRef)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Confidence indicator
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(index < confidenceLevel ? .green : .gray.opacity(0.3))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
                
                // Integration button
                HStack {
                    Spacer()
                    
                    Button(action: {
                        showingIntegrationSelection = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                                .font(.caption)
                            Text("Add to System")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(integrationManager.isProcessing)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showingIntegrationSelection) {
            IntegrationSelectionView(
                title: "Add Task to System",
                subtitle: "Choose where you'd like to add this task",
                onRemindersSelected: {
                    Task {
                        let success = await integrationManager.addTaskToReminders(task, recordingName: recordingName)
                        await MainActor.run {
                            if success {
                                showingSuccessAlert = true
                            } else {
                                showingErrorAlert = true
                            }
                        }
                    }
                },
                onCalendarSelected: {
                    Task {
                        let success = await integrationManager.addTaskToCalendar(task, recordingName: recordingName)
                        await MainActor.run {
                            if success {
                                showingSuccessAlert = true
                            } else {
                                showingErrorAlert = true
                            }
                        }
                    }
                }
            )
        }
        .alert("Success", isPresented: $showingSuccessAlert) {
            Button("OK") { }
        } message: {
            Text("Task successfully added to system.")
        }
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK") { }
        } message: {
            Text(integrationManager.lastError ?? "Failed to add task to system.")
        }
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var priorityColor: Color {
        switch task.priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .green
        }
    }
    
    private var categoryColor: Color {
        switch task.category {
        case .call: return .blue
        case .meeting: return .orange
        case .purchase: return .green
        case .research: return .indigo
        case .email: return .purple
        case .travel: return .cyan
        case .health: return .red
        case .general: return .gray
        }
    }
    
    private var confidenceLevel: Int {
        switch task.confidence {
        case 0.8...1.0: return 3
        case 0.6..<0.8: return 2
        default: return 1
        }
    }
}

// MARK: - Enhanced Reminder Row Component

struct EnhancedReminderRowView: View {
    let reminder: ReminderItem
    let recordingName: String
    @StateObject private var integrationManager = SystemIntegrationManager()
    @State private var showingIntegrationSelection = false
    @State private var showingSuccessAlert = false
    @State private var showingErrorAlert = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Urgency indicator
            Image(systemName: reminder.urgency.icon)
                .foregroundColor(urgencyColor)
                .font(.caption)
                .padding(.top, 2)
            
            // Reminder content
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(nil)
                
                // Reminder metadata
                HStack {
                    Text(reminder.urgency.rawValue)
                        .font(.caption2)
                        .foregroundColor(urgencyColor)
                        .fontWeight(.medium)
                    
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text(reminder.timeReference.displayText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // Confidence indicator
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(index < confidenceLevel ? .orange : .gray.opacity(0.3))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
                
                // Integration button
                HStack {
                    Spacer()
                    
                    Button(action: {
                        showingIntegrationSelection = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                                .font(.caption)
                            Text("Add to System")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(integrationManager.isProcessing)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showingIntegrationSelection) {
            IntegrationSelectionView(
                title: "Add Reminder to System",
                subtitle: "Choose where you'd like to add this reminder",
                onRemindersSelected: {
                    Task {
                        let success = await integrationManager.addReminderToReminders(reminder, recordingName: recordingName)
                        await MainActor.run {
                            if success {
                                showingSuccessAlert = true
                            } else {
                                showingErrorAlert = true
                            }
                        }
                    }
                },
                onCalendarSelected: {
                    Task {
                        let success = await integrationManager.addReminderToCalendar(reminder, recordingName: recordingName)
                        await MainActor.run {
                            if success {
                                showingSuccessAlert = true
                            } else {
                                showingErrorAlert = true
                            }
                        }
                    }
                }
            )
        }
        .alert("Success", isPresented: $showingSuccessAlert) {
            Button("OK") { }
        } message: {
            Text("Reminder successfully added to system.")
        }
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK") { }
        } message: {
            Text(integrationManager.lastError ?? "Failed to add reminder to system.")
        }
    }
    
    private var urgencyColor: Color {
        switch reminder.urgency {
        case .immediate: return .red
        case .today: return .orange
        case .thisWeek: return .yellow
        case .later: return .blue
        }
    }
    
    private var confidenceLevel: Int {
        switch reminder.confidence {
        case 0.8...1.0: return 3
        case 0.6..<0.8: return 2
        default: return 1
        }
    }
}

// MARK: - Selectable Title Row View

struct SelectableTitleRowView: View {
    let title: TitleItem
    let isCurrentTitle: Bool
    let onSelect: (TitleItem) -> Void
    let onEdit: (TitleItem) -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Selection indicator
            Button(action: {
                onSelect(title)
            }) {
                Image(systemName: isCurrentTitle ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isCurrentTitle ? .green : .gray)
            }
            .disabled(isCurrentTitle)
            
            VStack(alignment: .leading, spacing: 4) {
                // Title text
                Text(title.text)
                    .font(.body)
                    .foregroundColor(isCurrentTitle ? .green : .primary)
                    .fontWeight(isCurrentTitle ? .medium : .regular)
                    .multilineTextAlignment(.leading)
                
                // Title metadata
                HStack {
                    // Category
                    Image(systemName: title.category.icon)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text(title.category.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // Confidence
                    Text("\(SafeConfidenceHelper.percent(title.confidence))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if isCurrentTitle {
                        Text("Current")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            
            // Edit button
            Button(action: {
                onEdit(title)
            }) {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isCurrentTitle ? Color.green.opacity(0.05) : Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Title Selector View

struct TitleSelectorView: View {
    let titles: [TitleItem]
    let currentTitle: String
    let onTitleSelected: (String) -> Void
    let onCustomTitle: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var customTitleText = ""
    @State private var showingCustomTitleField = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose Recording Title")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Select from AI-generated titles or create your own")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                
                // Current title
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Current Title")
                            .font(.headline)
                        Spacer()
                    }
                    
                    Text(currentTitle)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()
                
                Divider()
                
                // Title options
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Generated titles section
                        if !titles.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "brain.head.profile")
                                        .foregroundColor(.blue)
                                    Text("AI-Generated Titles")
                                        .font(.headline)
                                    Spacer()
                                }
                                
                                ForEach(titles.sorted { $0.confidence > $1.confidence }, id: \.id) { title in
                                    TitleOptionRow(
                                        title: title,
                                        isSelected: title.text == currentTitle,
                                        onSelect: {
                                            onTitleSelected(title.text)
                                            dismiss()
                                        }
                                    )
                                }
                            }
                        }
                        
                        Divider()
                            .padding(.vertical)
                        
                        // Custom title section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "pencil")
                                    .foregroundColor(.orange)
                                Text("Custom Title")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            if showingCustomTitleField {
                                VStack(spacing: 12) {
                                    TextField("Enter custom title...", text: $customTitleText)
                                        .textFieldStyle(.roundedBorder)
                                    
                                    HStack {
                                        Button("Cancel") {
                                            showingCustomTitleField = false
                                            customTitleText = ""
                                        }
                                        .buttonStyle(.bordered)
                                        
                                        Spacer()
                                        
                                        Button("Use This Title") {
                                            onCustomTitle(customTitleText)
                                            dismiss()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(customTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                            } else {
                                Button(action: {
                                    showingCustomTitleField = true
                                    customTitleText = ""
                                }) {
                                    HStack {
                                        Image(systemName: "plus.circle")
                                        Text("Create Custom Title")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Title Option Row

struct TitleOptionRow: View {
    let title: TitleItem
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .green : .gray)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Title text
                    Text(title.text)
                        .font(.body)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Metadata
                    HStack {
                        Image(systemName: title.category.icon)
                            .font(.caption2)
                        Text(title.category.rawValue)
                            .font(.caption2)
                        
                        Spacer()
                        
                        // Confidence indicator
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { index in
                                Circle()
                                    .fill(index < confidenceLevel ? .blue : .gray.opacity(0.3))
                                    .frame(width: 4, height: 4)
                            }
                        }
                        
                        Text("\(SafeConfidenceHelper.percent(title.confidence))%")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.green.opacity(0.1) : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
    
    private var confidenceLevel: Int {
        guard title.confidence.isFinite else { return 1 }
        switch title.confidence {
        case 0.8...1.0: return 3
        case 0.6..<0.8: return 2
        default: return 1
        }
    }
}

// MARK: - Date/Time Editor View

struct DateTimeEditorView: View {
    let currentDate: Date
    let onDateTimeSelected: (Date) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    @State private var selectedTime: Date
    
    init(currentDate: Date, onDateTimeSelected: @escaping (Date) -> Void) {
        self.currentDate = currentDate
        self.onDateTimeSelected = onDateTimeSelected
        self._selectedDate = State(initialValue: currentDate)
        self._selectedTime = State(initialValue: currentDate)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set Recording Date & Time")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Choose the date and time when this recording was made")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                
                // Current date display
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.blue)
                        Text("Current Date & Time")
                            .font(.headline)
                        Spacer()
                    }
                    
                    Text(formatFullDateTime(currentDate))
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()
                
                Divider()
                
                // Date and time pickers
                ScrollView {
                    VStack(spacing: 24) {
                        // Date picker section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundColor(.orange)
                                Text("Select Date")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            DatePicker(
                                "Date",
                                selection: $selectedDate,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                        }
                        
                        Divider()
                        
                        // Time picker section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(.green)
                                Text("Select Time")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            DatePicker(
                                "Time",
                                selection: $selectedTime,
                                displayedComponents: .hourAndMinute
                            )
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(height: 120)
                        }
                        
                        // Preview section
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "eye")
                                    .foregroundColor(.purple)
                                Text("Preview")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            Text(formatFullDateTime(combinedDateTime))
                                .font(.body)
                                .fontWeight(.medium)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.purple.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        // Action buttons
                        VStack(spacing: 12) {
                            Button(action: {
                                onDateTimeSelected(combinedDateTime)
                                dismiss()
                            }) {
                                HStack {
                                    Image(systemName: "checkmark.circle")
                                    Text("Set This Date & Time")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            
                            Button(action: {
                                // Reset to file date (current original date)
                                onDateTimeSelected(currentDate)
                                dismiss()
                            }) {
                                HStack {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Reset to Original")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
    
    private var combinedDateTime: Date {
        let calendar = Calendar.current
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: selectedTime)
        
        var combined = DateComponents()
        combined.year = dateComponents.year
        combined.month = dateComponents.month
        combined.day = dateComponents.day
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute
        
        return calendar.date(from: combined) ?? selectedDate
    }
    
    private func formatFullDateTime(_ date: Date) -> String {
        return UserPreferences.shared.formatFullDateTime(date)
    }
}

// MARK: - Location Picker View

struct LocationPickerView: View {
    let onLocationSelected: (LocationData) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locationManager = LocationManager()
    @State private var searchText = ""
    @State private var searchResults: [LocationSearchResult] = []
    @State private var isSearching = false
    @State private var showingManualEntry = false
    @State private var manualLatitude = ""
    @State private var manualLongitude = ""
    @State private var selectedLocation: LocationData?
    @State private var isGettingCurrentLocation = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Recording Location")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Search for a location, use your current location, or enter coordinates manually")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                
                Divider()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Current location option
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "location")
                                    .foregroundColor(.blue)
                                Text("Use Current Location")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            Button(action: {
                                requestCurrentLocation()
                            }) {
                                HStack {
                                    if isGettingCurrentLocation {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "location.circle")
                                    }
                                    Text(isGettingCurrentLocation ? "Getting Location..." : "Get Current Location")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .background(isGettingCurrentLocation ? Color.gray : Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(isGettingCurrentLocation)
                        }
                        
                        Divider()
                        
                        // Search location option
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.green)
                                Text("Search Location")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            HStack {
                                TextField("Search for a place...", text: $searchText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        searchForLocation()
                                    }
                                
                                Button(action: searchForLocation) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            
                            if isSearching {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Searching...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            // Search results
                            if !searchResults.isEmpty {
                                VStack(spacing: 8) {
                                    ForEach(searchResults, id: \.id) { result in
                                        LocationResultRow(
                                            result: result,
                                            onSelect: { selectedResult in
                                                let locationData = LocationData(
                                                    latitude: selectedResult.latitude,
                                                    longitude: selectedResult.longitude,
                                                    timestamp: Date(),
                                                    accuracy: 5.0, // Approximate accuracy for search results
                                                    address: selectedResult.address
                                                )
                                                onLocationSelected(locationData)
                                                dismiss()
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        // Manual entry option
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "pencil")
                                    .foregroundColor(.orange)
                                Text("Manual Entry")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            if showingManualEntry {
                                VStack(spacing: 12) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text("Latitude")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            TextField("e.g. 37.7749", text: $manualLatitude)
                                                .textFieldStyle(.roundedBorder)
                                                .keyboardType(.decimalPad)
                                        }
                                        
                                        VStack(alignment: .leading) {
                                            Text("Longitude")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            TextField("e.g. -122.4194", text: $manualLongitude)
                                                .textFieldStyle(.roundedBorder)
                                                .keyboardType(.decimalPad)
                                        }
                                    }
                                    
                                    HStack {
                                        Button("Cancel") {
                                            showingManualEntry = false
                                            manualLatitude = ""
                                            manualLongitude = ""
                                        }
                                        .buttonStyle(.bordered)
                                        
                                        Spacer()
                                        
                                        Button("Use This Location") {
                                            useManualLocation()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(!isValidManualEntry)
                                    }
                                }
                            } else {
                                Button(action: {
                                    showingManualEntry = true
                                }) {
                                    HStack {
                                        Image(systemName: "plus.circle")
                                        Text("Enter Coordinates")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
    
    private var isValidManualEntry: Bool {
        guard let lat = Double(manualLatitude),
              let lng = Double(manualLongitude) else {
            return false
        }
        // Check for NaN, infinity, and valid coordinate ranges
        guard lat.isFinite && lng.isFinite && 
              !lat.isNaN && !lng.isNaN &&
              lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180 else {
            return false
        }
        return true
    }
    
    private func requestCurrentLocation() {
        print("🔍 Requesting current location...")
        isGettingCurrentLocation = true
        
        locationManager.requestCurrentLocation { location in
            DispatchQueue.main.async {
                guard let location = location else {
                    print("❌ Failed to get current location")
                    self.isGettingCurrentLocation = false
                    return
                }
                
                print("✅ Got current location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
                
                // Reverse geocode to get address
                self.locationManager.reverseGeocodeLocation(location) { address in
                    let finalLocationData = LocationData(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        timestamp: location.timestamp,
                        accuracy: location.horizontalAccuracy,
                        address: address ?? "Current Location"
                    )
                    
                    DispatchQueue.main.async {
                        self.isGettingCurrentLocation = false
                        self.onLocationSelected(finalLocationData)
                        self.dismiss()
                    }
                }
            }
        }
    }
    
    private func searchForLocation() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        isSearching = true
        searchResults = []
        
        let geocoder = CLGeocoder()
        
        geocoder.geocodeAddressString(searchText) { placemarks, error in
            DispatchQueue.main.async {
                self.isSearching = false
                
                if let error = error {
                    print("❌ Location search error: \(error)")
                    return
                }
                
                guard let placemarks = placemarks else {
                    print("⚠️ No placemarks found for search: \(self.searchText)")
                    return
                }
                
                // Convert placemarks to search results
                self.searchResults = placemarks.compactMap { placemark in
                    guard let coordinate = placemark.location?.coordinate else {
                        return nil
                    }
                    
                    // Build a formatted address
                    var addressComponents: [String] = []
                    
                    if let name = placemark.name {
                        addressComponents.append(name)
                    }
                    
                    if let locality = placemark.locality {
                        addressComponents.append(locality)
                    }
                    
                    if let administrativeArea = placemark.administrativeArea {
                        addressComponents.append(administrativeArea)
                    }
                    
                    if let country = placemark.country, country != "United States" {
                        addressComponents.append(country)
                    }
                    
                    let formattedAddress = addressComponents.joined(separator: ", ")
                    
                    return LocationSearchResult(
                        id: UUID(),
                        name: placemark.name ?? self.searchText,
                        address: formattedAddress,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                }
                
                print("✅ Found \(self.searchResults.count) location results for: \(self.searchText)")
            }
        }
    }
    
    private func useManualLocation() {
        guard let lat = Double(manualLatitude),
              let lng = Double(manualLongitude) else {
            print("❌ Failed to parse manual coordinates")
            return
        }
        
        // Additional safety check for NaN/infinite values
        guard lat.isFinite && lng.isFinite && 
              !lat.isNaN && !lng.isNaN &&
              lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180 else {
            print("❌ Invalid coordinate values: lat=\(lat), lng=\(lng)")
            return
        }
        
        let locationData = LocationData(
            latitude: lat,
            longitude: lng,
            timestamp: Date(),
            accuracy: 0.0, // Manual entry has no accuracy
            address: "Manual: \(lat), \(lng)"
        )
        
        print("✅ Using manual location: \(lat), \(lng)")
        onLocationSelected(locationData)
        dismiss()
    }
}

// MARK: - Location Search Result

struct LocationSearchResult {
    let id: UUID
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
}

// MARK: - Location Result Row

struct LocationResultRow: View {
    let result: LocationSearchResult
    let onSelect: (LocationSearchResult) -> Void
    
    var body: some View {
        Button(action: {
            onSelect(result)
        }) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(result.address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text("Lat: \(result.latitude, specifier: "%.4f"), Lng: \(result.longitude, specifier: "%.4f")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Helper Functions

struct SafeConfidenceHelper {
    static func percent(_ confidence: Double) -> Int {
        guard confidence.isFinite else { return 0 }
        return Int(confidence * 100)
    }
} 