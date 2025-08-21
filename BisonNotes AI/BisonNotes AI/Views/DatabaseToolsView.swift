//
//  DatabaseToolsView.swift
//  BisonNotes AI
//
//  Created by Claude on 8/21/25.
//

import SwiftUI

struct DatabaseToolsView: View {
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    private let enhancedFileManager = EnhancedFileManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var orphanedFiles: [URL] = []
    @State private var isScanning = false
    @State private var showingCleanupConfirmation = false
    @State private var showingCleanupResults = false
    @State private var cleanupResults: (deleted: Int, totalSize: Int64, errors: [String])? = nil
    @State private var totalOrphanedSize: Int64 = 0
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    orphanedFilesSection
                }
                .padding()
            }
            .navigationTitle("Database Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                scanForOrphanedFiles()
            }
            .alert("Confirm Cleanup", isPresented: $showingCleanupConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Files", role: .destructive) {
                    performCleanup()
                }
            } message: {
                Text("This will permanently delete \(orphanedFiles.count) orphaned audio files (\(formatFileSize(totalOrphanedSize))). This action cannot be undone.\n\nThese files exist on disk but are not referenced in your Core Data database.")
            }
            .alert("Cleanup Complete", isPresented: $showingCleanupResults) {
                Button("OK") {
                    scanForOrphanedFiles() // Refresh after cleanup
                }
            } message: {
                if let results = cleanupResults {
                    if results.errors.isEmpty {
                        Text("Successfully deleted \(results.deleted) files, freeing \(formatFileSize(results.totalSize)) of storage.")
                    } else {
                        Text("Deleted \(results.deleted) files, freeing \(formatFileSize(results.totalSize)) of storage.\n\nErrors: \(results.errors.joined(separator: ", "))")
                    }
                }
            }
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Database Maintenance")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("These tools help maintain your audio recording database by identifying and cleaning up orphaned files.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var orphanedFilesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orphaned Audio Files")
                        .font(.headline)
                    
                    Text("Audio files that exist on disk but are not referenced in your database")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: scanForOrphanedFiles) {
                    HStack(spacing: 6) {
                        if isScanning {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Scan")
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                .disabled(isScanning)
            }
            
            // Scan results
            if isScanning {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Scanning for orphaned files...")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if orphanedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                    
                    Text("No orphaned files found")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                    
                    Text("Your database is clean!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.green.opacity(0.1))
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(orphanedFiles.count) orphaned files found")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                            
                            Text("Total size: \(formatFileSize(totalOrphanedSize))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    // List of orphaned files (first 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Files to be deleted:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        ForEach(Array(orphanedFiles.prefix(10)), id: \.absoluteString) { file in
                            HStack {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                
                                Text(file.lastPathComponent)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Text(formatFileSize(getFileSize(file)))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if orphanedFiles.count > 10 {
                            Text("... and \(orphanedFiles.count - 10) more files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                    .padding(.leading, 16)
                    
                    // Warning and cleanup button
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            
                            Text("⚠️ Warning: This action cannot be undone")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.red)
                        }
                        
                        Text("These files will be permanently deleted from your device. Make sure you have backups if needed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Button("Delete Orphaned Files") {
                            showingCleanupConfirmation = true
                        }
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                        )
                    }
                    .padding(.top, 8)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                )
            }
        }
    }
    
    // MARK: - Actions
    
    private func scanForOrphanedFiles() {
        guard !isScanning else { return }
        
        isScanning = true
        orphanedFiles = []
        totalOrphanedSize = 0
        
        Task { @MainActor in
            let files = enhancedFileManager.findOrphanedAudioFiles(coordinator: appCoordinator)
            
            orphanedFiles = files
            
            // Calculate total size
            totalOrphanedSize = files.reduce(0) { total, file in
                total + getFileSize(file)
            }
            
            isScanning = false
        }
    }
    
    private func performCleanup() {
        Task { @MainActor in
            let results = enhancedFileManager.cleanupOrphanedAudioFiles(
                coordinator: appCoordinator,
                dryRun: false
            )
            
            cleanupResults = results
            showingCleanupResults = true
        }
    }
    
    // MARK: - Helpers
    
    private func getFileSize(_ url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#if DEBUG
struct DatabaseToolsView_Previews: PreviewProvider {
    static var previews: some View {
        DatabaseToolsView()
            .environmentObject(AppDataCoordinator())
    }
}
#endif