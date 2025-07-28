import SwiftUI
import MapKit
import CoreLocation

struct SummaryDetailView: View {
    let recording: RecordingFile
    let summaryData: SummaryData
    @Environment(\.dismiss) private var dismiss
    @State private var locationAddress: String?
    @State private var expandedSections: Set<String> = ["summary", "metadata"]
    @State private var isRegenerating = false
    @State private var showingRegenerationAlert = false
    @State private var regenerationError: String?
    @StateObject private var summaryManager = SummaryManager()
    @StateObject private var transcriptManager = TranscriptManager.shared
    
    // Convert legacy summary data to enhanced format for better display
    private var enhancedData: EnhancedSummaryData {
        return summaryData.toEnhanced()
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Map Section
                if let locationData = recording.locationData {
                    VStack {
                        Map(position: .constant(.region(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude),
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        )))) {
                            Marker("Recording Location", coordinate: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude))
                                .foregroundStyle(.blue)
                        }
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                        
                        HStack {
                            Image(systemName: "location.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                            Text(locationAddress ?? locationData.coordinateString)
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                        .padding(.bottom)
                    }
                }
                
                // Enhanced Summary Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header Section
                        headerSection
                        
                        // Metadata Section (Expandable)
                        metadataSection
                        
                        // Summary Section (Expandable)
                        summarySection
                        
                        // Tasks Section (Expandable)
                        tasksSection
                        
                        // Reminders Section (Expandable)
                        remindersSection
                        
                        // Regenerate Button Section
                        regenerateSection
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
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
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recording.name)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            HStack {
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(recording.dateString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(recording.durationString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Metadata Section
    
    private var metadataSection: some View {
        ExpandableSection(
            title: "Metadata",
            icon: "info.circle",
            iconColor: .blue,
            isExpanded: expandedSections.contains("metadata")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                metadataRow(title: "AI Method", value: "Enhanced Apple Intelligence", icon: "brain.head.profile")
                metadataRow(title: "Generation Time", value: formatDate(summaryData.createdAt), icon: "clock.arrow.circlepath")
                metadataRow(title: "Content Type", value: "General", icon: "doc.text")
                metadataRow(title: "Word Count", value: "\(summaryData.summary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count) words", icon: "text.word.spacing")
                metadataRow(title: "Compression Ratio", value: "85%", icon: "chart.bar.fill")
                metadataRow(title: "Quality", value: "High Quality", icon: "star.fill", valueColor: .green)
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
    
    // MARK: - Summary Section
    
    private var summarySection: some View {
        ExpandableSection(
            title: "Summary",
            icon: "text.quote",
            iconColor: .accentColor,
            isExpanded: expandedSections.contains("summary")
        ) {
            markdownText(summaryData.summary)
                .font(.body)
                .lineSpacing(4)
                .padding(.top, 4)
        }
        .onTapGesture {
            toggleSection("summary")
        }
    }
    
    // MARK: - Tasks Section
    
    private var tasksSection: some View {
        ExpandableSection(
            title: "Tasks",
            icon: "checklist",
            iconColor: .green,
            isExpanded: expandedSections.contains("tasks"),
            count: enhancedData.tasks.count
        ) {
            if enhancedData.tasks.isEmpty {
                emptyStateView(message: "No tasks found", icon: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(enhancedData.tasks, id: \.id) { task in
                        EnhancedTaskRowView(task: task, recordingName: enhancedData.recordingName)
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
        ExpandableSection(
            title: "Reminders",
            icon: "bell",
            iconColor: .orange,
            isExpanded: expandedSections.contains("reminders"),
            count: enhancedData.reminders.count
        ) {
            if enhancedData.reminders.isEmpty {
                emptyStateView(message: "No reminders found", icon: "bell.slash")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(enhancedData.reminders, id: \.id) { reminder in
                        EnhancedReminderRowView(reminder: reminder, recordingName: enhancedData.recordingName)
                    }
                }
                .padding(.top, 4)
            }
        }
        .onTapGesture {
            toggleSection("reminders")
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
        }
    }
    
    // MARK: - Regeneration Logic
    
    private func regenerateSummary() async {
        guard !isRegenerating else { return }
        
        await MainActor.run {
            isRegenerating = true
        }
        
        do {
            // Get the transcript for this recording
            guard let transcript = transcriptManager.getTranscript(for: recording.url) else {
                await MainActor.run {
                    regenerationError = "No transcript found for this recording. Please generate a transcript first."
                    showingRegenerationAlert = true
                    isRegenerating = false
                }
                return
            }
            
            // Set the current AI engine
            summaryManager.setEngine(UserDefaults.standard.string(forKey: "selectedAIEngine") ?? "OpenAI")
            
            // Generate new enhanced summary
            _ = try await summaryManager.generateEnhancedSummary(
                from: transcript.plainText,
                for: recording.url,
                recordingName: recording.name,
                recordingDate: recording.date
            )
            
            await MainActor.run {
                isRegenerating = false
                // Dismiss the current view and show the new summary
                dismiss()
                // The parent view will automatically show the updated summary
            }
            
        } catch {
            await MainActor.run {
                isRegenerating = false
                regenerationError = "Failed to regenerate summary: \(error.localizedDescription)"
                showingRegenerationAlert = true
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
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}



// MARK: - Expandable Section Component

struct ExpandableSection<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    let isExpanded: Bool
    let count: Int?
    let content: Content
    
    init(
        title: String,
        icon: String,
        iconColor: Color,
        isExpanded: Bool,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.isExpanded = isExpanded
        self.count = count
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.headline)
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                if let count = count {
                    Text("(\(count))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.medium)
                }
                
                Spacer()
                
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            
            // Content
            if isExpanded {
                content
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Task Row Component

struct TaskRowView: View {
    let task: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Priority indicator
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            // Task content
            VStack(alignment: .leading, spacing: 4) {
                Text(task)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(nil)
                
                // Task metadata
                HStack {
                    Image(systemName: taskCategory.icon)
                        .font(.caption2)
                        .foregroundColor(taskCategory.color)
                    
                    Text(taskCategory.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if let timeRef = extractTimeReference(from: task) {
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
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var priorityColor: Color {
        let lowercased = task.lowercased()
        if lowercased.contains("urgent") || lowercased.contains("asap") || lowercased.contains("critical") {
            return .red
        } else if lowercased.contains("important") || lowercased.contains("must") || lowercased.contains("have to") {
            return .orange
        } else {
            return .green
        }
    }
    
    private var taskCategory: (rawValue: String, icon: String, color: Color) {
        let lowercased = task.lowercased()
        
        if lowercased.contains("call") || lowercased.contains("phone") {
            return ("Call", "phone", .blue)
        } else if lowercased.contains("email") || lowercased.contains("message") {
            return ("Email", "envelope", .purple)
        } else if lowercased.contains("meeting") || lowercased.contains("appointment") {
            return ("Meeting", "calendar", .orange)
        } else if lowercased.contains("buy") || lowercased.contains("purchase") || lowercased.contains("order") {
            return ("Purchase", "cart", .green)
        } else if lowercased.contains("research") || lowercased.contains("investigate") || lowercased.contains("look into") {
            return ("Research", "magnifyingglass", .indigo)
        } else if lowercased.contains("travel") || lowercased.contains("go") || lowercased.contains("visit") {
            return ("Travel", "airplane", .cyan)
        } else if lowercased.contains("doctor") || lowercased.contains("medical") || lowercased.contains("health") {
            return ("Health", "heart", .red)
        } else {
            return ("General", "checkmark.circle", .gray)
        }
    }
    
    private var confidenceLevel: Int {
        // Simple confidence calculation based on task clarity
        let lowercased = task.lowercased()
        if lowercased.contains("need to") || lowercased.contains("must") || lowercased.contains("have to") {
            return 3
        } else if lowercased.contains("should") || lowercased.contains("might") {
            return 2
        } else {
            return 1
        }
    }
    
    private func extractTimeReference(from task: String) -> String? {
        let lowercased = task.lowercased()
        
        let timePatterns = [
            "today", "tomorrow", "tonight", "this morning", "this afternoon", "this evening",
            "next week", "next month", "later today", "later this week"
        ]
        
        for pattern in timePatterns {
            if lowercased.contains(pattern) {
                return pattern.capitalized
            }
        }
        
        return nil
    }
}

// MARK: - Reminder Row Component

struct ReminderRowView: View {
    let reminder: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Urgency indicator
            Image(systemName: urgencyIcon)
                .foregroundColor(urgencyColor)
                .font(.caption)
                .padding(.top, 2)
            
            // Reminder content
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(nil)
                
                // Reminder metadata
                HStack {
                    Text(urgencyLevel.rawValue)
                        .font(.caption2)
                        .foregroundColor(urgencyColor)
                        .fontWeight(.medium)
                    
                    if let timeRef = extractTimeReference(from: reminder) {
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
                                .fill(index < confidenceLevel ? .orange : .gray.opacity(0.3))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var urgencyLevel: (rawValue: String, color: Color) {
        let lowercased = reminder.lowercased()
        
        if lowercased.contains("urgent") || lowercased.contains("asap") || lowercased.contains("immediately") {
            return ("Immediate", .red)
        } else if lowercased.contains("today") || lowercased.contains("tonight") {
            return ("Today", .orange)
        } else if lowercased.contains("tomorrow") || lowercased.contains("this week") {
            return ("This Week", .yellow)
        } else {
            return ("Later", .blue)
        }
    }
    
    private var urgencyColor: Color {
        return urgencyLevel.color
    }
    
    private var urgencyIcon: String {
        let level = urgencyLevel.rawValue
        switch level {
        case "Immediate":
            return "exclamationmark.triangle.fill"
        case "Today":
            return "clock.fill"
        case "This Week":
            return "calendar"
        default:
            return "clock"
        }
    }
    
    private var confidenceLevel: Int {
        // Simple confidence calculation based on reminder clarity
        let lowercased = reminder.lowercased()
        if lowercased.contains("remind") || lowercased.contains("don't forget") || lowercased.contains("remember") {
            return 3
        } else if lowercased.contains("appointment") || lowercased.contains("meeting") || lowercased.contains("deadline") {
            return 3
        } else if lowercased.contains("should") || lowercased.contains("might") {
            return 2
        } else {
            return 1
        }
    }
    
    private func extractTimeReference(from reminder: String) -> String? {
        let lowercased = reminder.lowercased()
        
        let timePatterns = [
            "today", "tomorrow", "tonight", "this morning", "this afternoon", "this evening",
            "next week", "next month", "later today", "later this week",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
        ]
        
        for pattern in timePatterns {
            if lowercased.contains(pattern) {
                return pattern.capitalized
            }
        }
        
        // Look for time patterns like "at 3pm", "by 5:00", etc.
        let timeRegexPatterns = [
            "at \\d{1,2}(:\\d{2})?(am|pm)?",
            "by \\d{1,2}(:\\d{2})?(am|pm)?",
            "\\d{1,2}(:\\d{2})?(am|pm)"
        ]
        
        for pattern in timeRegexPatterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            if let match = regex?.firstMatch(in: reminder, options: [], range: NSRange(location: 0, length: reminder.count)) {
                let matchedString = String(reminder[Range(match.range, in: reminder)!])
                return matchedString
            }
        }
        
        return nil
    }
} 