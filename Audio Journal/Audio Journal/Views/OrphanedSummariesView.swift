import SwiftUI

struct OrphanedSummariesView: View {
    @StateObject private var enhancedFileManager = EnhancedFileManager.shared
    @StateObject private var summaryManager = SummaryManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var orphanedSummaries: [FileRelationships] = []
    @State private var summaryToDelete: FileRelationships?
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        NavigationView {
            VStack {
                if orphanedSummaries.isEmpty {
                    emptyStateView
                } else {
                    orphanedSummariesList
                }
            }
            .navigationTitle("Orphaned Summaries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Delete Summary", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    summaryToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let relationships = summaryToDelete {
                        deleteSummary(relationships)
                    }
                    summaryToDelete = nil
                }
            } message: {
                if let relationships = summaryToDelete {
                    Text("Are you sure you want to delete the summary for '\(relationships.recordingName)'? This action cannot be undone.")
                }
            }
        }
        .onAppear {
            loadOrphanedSummaries()
        }
    }
    
    private func loadOrphanedSummaries() {
        orphanedSummaries = enhancedFileManager.getOrphanedSummaries()
    }
    
    private func deleteSummary(_ relationships: FileRelationships) {
        Task {
            do {
                // Create a placeholder URL for the deletion if needed
                let url = relationships.recordingURL ?? createPlaceholderURL(for: relationships.recordingName)
                try await enhancedFileManager.deleteSummary(for: url)
                
                await MainActor.run {
                    loadOrphanedSummaries()
                }
                
                print("✅ Orphaned summary deleted: \(relationships.recordingName)")
            } catch {
                print("❌ Error deleting orphaned summary: \(error)")
                // TODO: Show error alert to user
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Orphaned Summaries")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            Text("Summaries whose original recordings have been deleted will appear here")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var orphanedSummariesList: some View {
        List {
            ForEach(orphanedSummaries) { relationships in
                orphanedSummaryRow(relationships)
            }
        }
    }
    
    private func orphanedSummaryRow(_ relationships: FileRelationships) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(relationships.recordingName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(relationships.recordingDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    FileAvailabilityIndicator(
                        status: relationships.availabilityStatus,
                        showLabel: true,
                        size: .small
                    )
                    
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text("Original recording no longer available")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    // View summary button
                    let recordingURL = relationships.recordingURL ?? createPlaceholderURL(for: relationships.recordingName)
                    if let summaryData = summaryManager.getBestAvailableSummary(for: recordingURL) {
                        let recordingFile = createRecordingFile(from: relationships, url: recordingURL)
                        NavigationLink(destination: EnhancedSummaryDetailView(recording: recordingFile, summaryData: summaryData)) {
                            Image(systemName: "doc.text")
                                .foregroundColor(.blue)
                                .font(.title3)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    // Delete summary button
                    Button(action: {
                        summaryToDelete = relationships
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
    
    private func createPlaceholderURL(for recordingName: String) -> URL {
        // Create a placeholder URL for orphaned summaries
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("\(recordingName).m4a")
    }
    
    private func createRecordingFile(from relationships: FileRelationships, url: URL) -> RecordingFile {
        // Create a RecordingFile from the relationships data
        return RecordingFile(
            url: url,
            name: relationships.recordingName,
            date: relationships.recordingDate,
            duration: 0, // Duration not available for orphaned recordings
            locationData: nil // Location data not available for orphaned recordings
        )
    }
}

struct OrphanedSummariesView_Previews: PreviewProvider {
    static var previews: some View {
        OrphanedSummariesView()
    }
}