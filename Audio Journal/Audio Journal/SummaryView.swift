import SwiftUI
import MapKit
import NaturalLanguage
import CoreLocation

struct SummaryView: View {
    let recording: RecordingFile
    let transcriptText: String
    @Environment(\.dismiss) private var dismiss
    @State private var locationAddress: String?
    @State private var summary: String = ""
    @State private var tasks: [String] = []
    @State private var reminders: [String] = []
    @State private var isGeneratingSummary = false
    
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
                
                // Summary Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text(recording.name)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text(recording.dateString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        
                        if isGeneratingSummary {
                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Generating summary...")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 50)
                        } else {
                            // Summary Section
                            if !summary.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Image(systemName: "text.quote")
                                            .foregroundColor(.accentColor)
                                        Text("Summary")
                                            .font(.headline)
                                            .fontWeight(.semibold)
                                    }
                                    
                                                                markdownText(summary)
                                .font(.body)
                                .lineSpacing(4)
                                }
                                .padding(.horizontal)
                            }
                            
                            // Tasks Section
                            if !tasks.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Image(systemName: "checklist")
                                            .foregroundColor(.green)
                                        Text("Tasks")
                                            .font(.headline)
                                            .fontWeight(.semibold)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(tasks, id: \.self) { task in
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: "circle")
                                                    .font(.caption)
                                                    .foregroundColor(.green)
                                                    .padding(.top, 2)
                                                Text(task)
                                                    .font(.body)
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                            
                            // Reminders Section
                            if !reminders.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Image(systemName: "bell")
                                            .foregroundColor(.orange)
                                        Text("Reminders")
                                            .font(.headline)
                                            .fontWeight(.semibold)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(reminders, id: \.self) { reminder in
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: "bell")
                                                    .font(.caption)
                                                    .foregroundColor(.orange)
                                                    .padding(.top, 2)
                                                Text(reminder)
                                                    .font(.body)
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
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
                
                if !transcriptText.isEmpty {
                    generateSummary()
                }
            }
        }
    }
    
    private func generateSummary() {
        isGeneratingSummary = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let summaryResult = generateSummaryFromText(transcriptText)
            let tasksResult = extractTasksFromText(transcriptText)
            let remindersResult = extractRemindersFromText(transcriptText)
            
            DispatchQueue.main.async {
                self.summary = summaryResult
                self.tasks = tasksResult
                self.reminders = remindersResult
                self.isGeneratingSummary = false
            }
        }
    }
    
    private func generateSummaryFromText(_ text: String) -> String {
        // Use Natural Language framework for summarization
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        
        // Simple extractive summarization using sentence importance
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        guard !sentences.isEmpty else { return "No content to summarize." }
        
        // Score sentences based on key terms and length
        var sentenceScores: [(String, Double)] = []
        
        for sentence in sentences {
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanSentence.isEmpty else { continue }
            
            var score: Double = 0
            
            // Score based on length (prefer medium-length sentences)
            let wordCount = cleanSentence.components(separatedBy: CharacterSet.whitespaces).count
            if wordCount >= 5 && wordCount <= 20 {
                score += 2.0
            } else if wordCount > 20 {
                score += 1.0
            }
            
            // Score based on key terms
            let lowercased = cleanSentence.lowercased()
            let keyTerms = ["important", "need", "must", "should", "remember", "remind", "call", "meet", "buy", "get", "do", "make", "see", "visit", "go", "come", "take", "bring"]
            
            for term in keyTerms {
                if lowercased.contains(term) {
                    score += 1.0
                }
            }
            
            // Score based on time references
            let timePatterns = ["today", "tomorrow", "next", "later", "tonight", "morning", "afternoon", "evening", "week", "month", "year"]
            for pattern in timePatterns {
                if lowercased.contains(pattern) {
                    score += 1.5
                }
            }
            
            sentenceScores.append((cleanSentence, score))
        }
        
        // Sort by score and take top sentences
        let sortedSentences = sentenceScores.sorted { $0.1 > $1.1 }
        let topSentences = Array(sortedSentences.prefix(min(3, sortedSentences.count)))
        
        if topSentences.isEmpty {
            return "Summary: " + sentences.prefix(2).joined(separator: ". ") + "."
        }
        
        let summaryText = topSentences.map { $0.0 }.joined(separator: ". ") + "."
        return "Summary: " + summaryText
    }
    
    private func extractTasksFromText(_ text: String) -> [String] {
        var tasks: [String] = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        
        let taskKeywords = [
            "need to", "have to", "must", "should", "want to", "going to", "plan to",
            "call", "meet", "buy", "get", "do", "make", "see", "visit", "go", "come",
            "take", "bring", "send", "email", "text", "message", "schedule", "book",
            "order", "pick up", "drop off", "return", "check", "review", "update"
        ]
        
        for sentence in sentences {
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = cleanSentence.lowercased()
            
            for keyword in taskKeywords {
                if lowercased.contains(keyword) {
                    // Extract the task part
                    if let range = lowercased.range(of: keyword) {
                        let taskStart = cleanSentence.index(cleanSentence.startIndex, offsetBy: range.lowerBound.utf16Offset(in: lowercased))
                        let taskText = String(cleanSentence[taskStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if !taskText.isEmpty && taskText.count > 5 {
                            tasks.append(taskText.capitalized)
                            break // Only add each sentence once
                        }
                    }
                }
            }
        }
        
        return Array(Set(tasks)).prefix(5).map { $0 } // Remove duplicates and limit to 5
    }
    
    private func extractRemindersFromText(_ text: String) -> [String] {
        var reminders: [String] = []
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        
        let reminderKeywords = [
            "remind", "remember", "don't forget", "don't forget to", "make sure to",
            "call", "meet", "appointment", "meeting", "deadline", "due", "by", "at"
        ]
        
        let timePatterns = [
            "today", "tomorrow", "tonight", "morning", "afternoon", "evening",
            "next week", "next month", "next year", "later", "soon", "in an hour",
            "at 7", "at 8", "at 9", "at 10", "at 11", "at 12", "at 1", "at 2", "at 3", "at 4", "at 5", "at 6"
        ]
        
        for sentence in sentences {
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = cleanSentence.lowercased()
            
            var hasReminderKeyword = false
            var hasTimeReference = false
            
            // Check for reminder keywords
            for keyword in reminderKeywords {
                if lowercased.contains(keyword) {
                    hasReminderKeyword = true
                    break
                }
            }
            
            // Check for time references
            for pattern in timePatterns {
                if lowercased.contains(pattern) {
                    hasTimeReference = true
                    break
                }
            }
            
            if hasReminderKeyword || hasTimeReference {
                if cleanSentence.count > 5 {
                    reminders.append(cleanSentence.capitalized)
                }
            }
        }
        
        return Array(Set(reminders)).prefix(5).map { $0 } // Remove duplicates and limit to 5
    }
} 