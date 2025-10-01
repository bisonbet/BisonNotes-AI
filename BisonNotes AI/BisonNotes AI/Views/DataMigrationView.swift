//
//  DataMigrationView.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import SwiftUI

enum MigrationMode {
    case migration
    case integrityCheck
    case repair
}

struct DataMigrationView: View {
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var migrationManager = DataMigrationManager()
    @StateObject private var legacyiCloudManager = iCloudStorageManager()
    @Environment(\.dismiss) private var dismiss
    @State private var integrityReport: DataIntegrityReport?
    @State private var repairResults: DataRepairResults?
    @State private var currentMode: MigrationMode = .migration
    @State private var showingClearDatabaseAlert = false
    @State private var isInitialized = false
    @State private var showingCleanupAlert = false
    @State private var isPerformingCleanup = false
    @State private var cleanupResults: CleanupResults?
    // Safety confirmations for data-changing operations
    @State private var confirmRecoverCloud = false
    @State private var confirmRepairDuplicates = false
    @State private var confirmFixNamesListings = false
    @State private var confirmFullSyncToCloud = false
    @State private var confirmCloudKitReset = false
    @State private var confirmRemoveImportedFiles = false
    @State private var confirmFixInvalidURLs = false
    @State private var confirmCleanupMissingAudio = false
    
    // Orphaned audio file cleanup
    @State private var orphanedAudioFiles: [URL] = []
    @State private var showingOrphanedFilesCleanup = false
    @State private var showingOrphanedFilesResults = false
    @State private var orphanedFilesResults: (deleted: Int, totalSize: Int64, errors: [String])? = nil
    @State private var totalOrphanedSize: Int64 = 0
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 30) {
                    headerSection
                    
                    if migrationManager.migrationProgress > 0 {
                        progressSection
                    }
                    
                    switch currentMode {
                    case .migration:
                        migrationSection
                    case .integrityCheck:
                        integrityCheckSection
                    case .repair:
                        repairSection
                    }
                    
                    if integrityReport != nil || repairResults != nil {
                        resultsSection
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("⚠️ DESTRUCTIVE ACTION - Clear All Database Data", isPresented: $showingClearDatabaseAlert) {
                Button("Cancel", role: .cancel) { }
                Button("I Understand - Delete Everything", role: .destructive) {
                    Task {
                        await migrationManager.clearAllCoreData()
                    }
                }
            } message: {
                Text("🚨 CRITICAL WARNING 🚨\n\nThis will PERMANENTLY DELETE ALL of your data from the database:\n\n❌ ALL TRANSCRIPTS (cannot be recovered)\n❌ ALL SUMMARIES (cannot be recovered)\n❌ ALL RECORDING METADATA\n\n✅ Your audio files will remain on disk\n\n⚠️ This action CANNOT be undone and you will lose all your transcribed text and AI-generated summaries forever.\n\nOnly proceed if you understand this will destroy all your transcript and summary data.")
            }
            .alert("Cleanup Orphaned Data", isPresented: $showingCleanupAlert) {
                Button("Cancel") {
                    showingCleanupAlert = false
                }
                Button("Clean Up") {
                    Task {
                        await performCleanup()
                    }
                    showingCleanupAlert = false
                }
            } message: {
                Text("This will remove summaries and transcripts for recordings that no longer exist. This action cannot be undone.")
            }
            .alert("Upload All Summaries to iCloud", isPresented: $confirmFullSyncToCloud) {
                Button("Cancel", role: .cancel) { }
                Button("Upload All") {
                    Task {
                        do {
                            try await legacyiCloudManager.performOneTimeFullSync()
                            print("✅ Successfully uploaded all summaries to iCloud")
                        } catch {
                            print("❌ Failed to upload summaries: \(error)")
                        }
                    }
                }
            } message: {
                Text("This will upload ALL local summaries to iCloud. This is useful for:\n\n• Initial setup on a new device\n• After restoring from backup\n• Manual full synchronization\n\nThis may take several minutes depending on the number of summaries.")
            }
            .alert("⚠️ RESET CLOUDKIT & FRESH SYNC", isPresented: $confirmCloudKitReset) {
                Button("Cancel", role: .cancel) { }
                Button("Reset & Sync", role: .destructive) {
                    Task {
                        do {
                            let result = try await legacyiCloudManager.performFullCloudKitResetAndSync(appCoordinator: appCoordinator)
                            print("✅ CloudKit reset complete: deleted \(result.deleted), uploaded \(result.uploaded)")
                        } catch {
                            print("❌ Failed to reset CloudKit: \(error)")
                        }
                    }
                }
            } message: {
                Text("🚨 DESTRUCTIVE ACTION 🚨\n\nThis will:\n\n1️⃣ DELETE ALL summaries from iCloud\n2️⃣ Upload fresh copies of all your current summaries\n\nThis is the nuclear option for fixing CloudKit sync issues. Use this when:\n\n• CloudKit has orphaned or duplicate data\n• Sync is completely broken\n• You want a clean slate\n\n⚠️ This cannot be undone and may take several minutes.")
            }
            .alert("Remove Orphaned Import Files", isPresented: $confirmRemoveImportedFiles) {
                Button("Cancel", role: .cancel) { }
                Button("Remove", role: .destructive) {
                    Task {
                        await removeOrphanedImportFiles()
                    }
                }
            } message: {
                Text("This will remove Core Data recordings that:\n\n• Have names starting with 'importedfile-'\n• Have no transcript data\n• Have no summary data\n\nThis fixes duplicate recordings created during import processes. Your real recordings with transcripts and summaries will be preserved.")
            }
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: headerIcon)
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            
            Text(headerTitle)
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text(headerDescription)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
    
    private var progressSection: some View {
        VStack(spacing: 16) {
            ProgressView(value: migrationManager.migrationProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
            
            Text(migrationManager.migrationStatus)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }
    
    private var migrationSection: some View {
        VStack(spacing: 16) {
            // Primary action - Check for issues
            Button(action: {
                currentMode = .integrityCheck
            }) {
                HStack {
                    Image(systemName: "magnifyingglass.circle.fill")
                    Text("Check for Issues")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.accentColor)
                .cornerRadius(12)
            }
            
            // iCloud Recovery
            Button(action: {
                confirmRecoverCloud = true
            }) {
                HStack {
                    Image(systemName: "icloud.and.arrow.down")
                    Text("Recover from iCloud")
                }
                .font(.headline)
                .foregroundColor(.purple)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.purple.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.purple, lineWidth: 1)
                )
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
            
            // Full sync to cloud (manual upload all)
            Button(action: {
                confirmFullSyncToCloud = true
            }) {
                HStack {
                    Image(systemName: "icloud.and.arrow.up")
                    Text("Upload All Summaries to iCloud")
                }
                .font(.headline)
                .foregroundColor(.blue)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
            
            // Full CloudKit reset and fresh sync
            Button(action: {
                confirmCloudKitReset = true
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise.icloud")
                    Text("Reset CloudKit & Fresh Sync")
                }
                .font(.headline)
                .foregroundColor(.orange)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange, lineWidth: 1)
                )
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
            
            // Remove orphaned importedfile entries
            Button(action: {
                confirmRemoveImportedFiles = true
            }) {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("Remove Orphaned Import Files")
                }
                .font(.headline)
                .foregroundColor(.red)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red, lineWidth: 1)
                )
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
            
            // Orphaned audio files cleanup
            Button(action: {
                Task {
                    await scanForOrphanedAudioFiles()
                }
            }) {
                HStack {
                    Image(systemName: "waveform.badge.xmark")
                    Text("Find Orphaned Audio Files")
                }
                .font(.headline)
                .foregroundColor(.orange)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange, lineWidth: 1)
                )
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
            
            // Show orphaned files if found
            if !orphanedAudioFiles.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(orphanedAudioFiles.count) orphaned audio files found")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                            
                            Text("Total size: \(formatFileSize(totalOrphanedSize))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    Button("Delete Orphaned Audio Files") {
                        showingOrphanedFilesCleanup = true
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
            
            // Fix invalid URLs
            Button(action: {
                confirmFixInvalidURLs = true
            }) {
                HStack {
                    Image(systemName: "link.badge.plus")
                    Text("Fix Broken File Links")
                }
                .font(.headline)
                .foregroundColor(.blue)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
            
            // Clean up missing audio references
            Button(action: {
                confirmCleanupMissingAudio = true
            }) {
                HStack {
                    Image(systemName: "trash.slash")
                    Text("Clean Up Missing Audio")
                }
                .font(.headline)
                .foregroundColor(.orange)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange, lineWidth: 1)
                )
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
            
            // Fix filename/title duplicates (the new advanced repair)
            Button(action: {
                confirmRepairDuplicates = true
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.merge")
                    Text("Repair Duplicates (Keep Summary Title)")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.green)
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
            
            // Fix current naming and transcript listing issues
            Button(action: {
                confirmFixNamesListings = true
            }) {
                HStack {
                    Image(systemName: "textformat")
                    Text("Fix Names & Transcript Listings")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.purple)
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)

            // Repair orphaned summaries
            Button(action: {
                Task {
                    await MainActor.run {
                        let repairedCount = appCoordinator.coreDataManager.repairOrphanedSummaries()
                        print("🔧 Manual repair completed: \(repairedCount) summaries repaired")
                    }
                }
            }) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                    Text("Repair Orphaned Summaries")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.orange)
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)

            // Cleanup Orphaned Data section
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cleanup Orphaned Data")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text("Remove summaries and transcripts for deleted recordings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        showingCleanupAlert = true
                    }) {
                        HStack {
                            if isPerformingCleanup {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 4)
                            }
                            Text(isPerformingCleanup ? "Cleaning..." : "Clean Up")
                        }
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isPerformingCleanup ? Color.gray : Color.orange)
                        )
                    }
                    .disabled(isPerformingCleanup)
                }
                
                if let results = cleanupResults {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Cleanup Results:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        Text("• Removed \(results.orphanedSummaries) orphaned summaries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("• Removed \(results.orphanedTranscripts) orphaned transcripts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("• Removed \(results.orphanedRecordings) orphaned recordings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("• Freed \(results.freedSpaceMB, specifier: "%.1f") MB of space")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(.systemGray6).opacity(0.5))
            .cornerRadius(8)
            
            // Debug info
            Button(action: {
                Task {
                    await migrationManager.debugCoreDataContents()
                }
            }) {
                HStack {
                    Image(systemName: "info.circle")
                    Text("View Database Info")
                }
                .font(.headline)
                .foregroundColor(.blue)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
                .cornerRadius(12)
            }
            
            // Destructive action - Clear database
            Button(action: {
                showingClearDatabaseAlert = true
            }) {
                HStack {
                    Image(systemName: "trash.circle")
                    Text("Clear All Data")
                }
                .font(.headline)
                .foregroundColor(.red)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red, lineWidth: 1)
                )
                .cornerRadius(12)
            }
        }
        .padding(.horizontal)
        // MARK: - Safety Alerts
        .alert("Recover from iCloud", isPresented: $confirmRecoverCloud) {
            Button("Cancel", role: .cancel) { }
            Button("Recover", role: .destructive) {
                Task {
                    migrationManager.setCloudSyncManagers(legacy: legacyiCloudManager)
                    let _ = await migrationManager.recoverDataFromiCloud()
                }
            }
        } message: {
            Text("This will fetch summaries from iCloud and add any missing entries to your database. It will not overwrite existing local summaries.")
        }
        .alert("Repair Duplicates", isPresented: $confirmRepairDuplicates) {
            Button("Cancel", role: .cancel) { }
            Button("Repair", role: .destructive) {
                Task {
                    let _ = await migrationManager.fixSpecificDataIssues()
                }
            }
        } message: {
            Text("Merges duplicate recordings that point to the same file and deletes the duplicate entries. The summary-generated title will be preserved.")
        }
        .alert("Fix Names & Transcript Listings", isPresented: $confirmFixNamesListings) {
            Button("Cancel", role: .cancel) { }
            Button("Fix", role: .destructive) {
                Task {
                    let _ = await migrationManager.fixCurrentIssues()
                }
            }
        } message: {
            Text("Renames generic recordings to better titles where available and validates statuses. No files will be deleted.")
        }
        .alert("Fix Broken File Links", isPresented: $confirmFixInvalidURLs) {
            Button("Cancel", role: .cancel) { }
            Button("Fix Links", role: .destructive) {
                Task {
                    let _ = await migrationManager.fixInvalidURLs()
                }
            }
        } message: {
            Text("This will attempt to reconnect recordings with broken file paths to existing audio files by matching names. This fixes the 'Could not get absolute URL' errors you're seeing.")
        }
        .alert("Clean Up Missing Audio", isPresented: $confirmCleanupMissingAudio) {
            Button("Cancel", role: .cancel) { }
            Button("Clean Up", role: .destructive) {
                Task {
                    let _ = await migrationManager.cleanupMissingAudioReferences()
                }
            }
        } message: {
            Text("This will clean up recordings with missing audio files:\n\n• Clear broken audio file references\n• DELETE transcripts (useless without audio)\n• PRESERVE summaries (valuable processed data)\n\nRecordings will show as 'Summary Only'.")
        }
        .alert("Confirm Cleanup", isPresented: $showingOrphanedFilesCleanup) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Files", role: .destructive) {
                Task {
                    await performOrphanedFilesCleanup()
                }
            }
        } message: {
            Text("This will permanently delete \(orphanedAudioFiles.count) orphaned audio files (\(formatFileSize(totalOrphanedSize))). This action cannot be undone.\n\nThese files exist on disk but are not referenced in your Core Data database.")
        }
        .alert("Cleanup Complete", isPresented: $showingOrphanedFilesResults) {
            Button("OK") {
                Task {
                    await scanForOrphanedAudioFiles() // Refresh after cleanup
                }
            }
        } message: {
            if let results = orphanedFilesResults {
                if results.errors.isEmpty {
                    Text("Successfully deleted \(results.deleted) files, freeing \(formatFileSize(results.totalSize)) of storage.")
                } else {
                    Text("Deleted \(results.deleted) files, freeing \(formatFileSize(results.totalSize)) of storage.\n\nErrors: \(results.errors.joined(separator: ", "))")
                }
            }
        }
    }
    
    private var integrityCheckSection: some View {
        VStack(spacing: 16) {
            Button(action: {
                Task {
                    integrityReport = await migrationManager.performDataIntegrityCheck()
                }
            }) {
                HStack {
                    Image(systemName: "play.circle.fill")
                    Text("Start Integrity Check")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.orange)
                .cornerRadius(12)
            }
            .disabled(migrationManager.migrationProgress > 0 && migrationManager.migrationProgress < 1.0)
            
            Button(action: {
                currentMode = .migration
                integrityReport = nil
            }) {
                HStack {
                    Image(systemName: "arrow.left.circle")
                    Text("Back to Migration")
                }
                .font(.headline)
                .foregroundColor(.blue)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
                .cornerRadius(12)
            }
        }
        .padding(.horizontal)
    }
    
    private var repairSection: some View {
        VStack(spacing: 16) {
            if let report = integrityReport {
                Button(action: {
                    Task {
                        repairResults = await migrationManager.repairDataIntegrityIssues(report: report)
                    }
                }) {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                        Text("Start Repair")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(12)
                }
                .disabled(migrationManager.migrationProgress > 0 && migrationManager.migrationProgress < 1.0)
            }
            
            Button(action: {
                currentMode = .integrityCheck
                repairResults = nil
            }) {
                HStack {
                    Image(systemName: "arrow.left.circle")
                    Text("Back to Integrity Check")
                }
                .font(.headline)
                .foregroundColor(.blue)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
                .cornerRadius(12)
            }
        }
        .padding(.horizontal)
    }
    
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let report = integrityReport {
                Text("Integrity Check Results")
                    .font(.headline)
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: report.hasIssues ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(report.hasIssues ? .orange : .green)
                        Text(report.hasIssues ? "Issues Found: \(report.totalIssues)" : "No Issues Found")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    if report.hasIssues {
                        VStack(alignment: .leading, spacing: 4) {
                            if !report.orphanedRecordings.isEmpty {
                                Text("• \(report.orphanedRecordings.count) recordings missing transcript/summary links")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !report.orphanedFiles.isEmpty {
                                Text("• \(report.orphanedFiles.count) orphaned transcript/summary files")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !report.brokenRelationships.isEmpty {
                                Text("• \(report.brokenRelationships.count) broken database relationships")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !report.missingAudioFiles.isEmpty {
                                Text("• \(report.missingAudioFiles.count) recordings with missing audio files")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !report.duplicateEntries.isEmpty {
                                Text("• \(report.duplicateEntries.count) sets of duplicate entries")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading)
                        
                        Button(action: {
                            currentMode = .repair
                        }) {
                            HStack {
                                Image(systemName: "wrench.fill")
                                Text("Repair Issues")
                            }
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.green)
                            .cornerRadius(8)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)
            }
            
            if let results = repairResults {
                Text("Repair Results")
                    .font(.headline)
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Repairs Completed: \(results.totalRepairs)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    if results.totalRepairs > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            if results.repairedOrphanedRecordings > 0 {
                                Text("• \(results.repairedOrphanedRecordings) orphaned recordings repaired")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if results.importedOrphanedFiles > 0 {
                                Text("• \(results.importedOrphanedFiles) orphaned files imported")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if results.repairedRelationships > 0 {
                                Text("• \(results.repairedRelationships) broken relationships repaired")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if results.cleanedMissingFiles > 0 {
                                Text("• \(results.cleanedMissingFiles) entries with missing files cleaned")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }
    
    private var navigationTitle: String {
        switch currentMode {
        case .migration:
            return "Database Tools"
        case .integrityCheck:
            return "Integrity Check"
        case .repair:
            return "Data Repair"
        }
    }
    
    private var headerIcon: String {
        switch currentMode {
        case .migration:
            return "arrow.triangle.2.circlepath"
        case .integrityCheck:
            return "magnifyingglass"
        case .repair:
            return "wrench.and.screwdriver"
        }
    }
    
    private var headerTitle: String {
        switch currentMode {
        case .migration:
            return "Database Tools"
        case .integrityCheck:
            return "Data Integrity Check"
        case .repair:
            return "Data Repair"
        }
    }
    
    private var headerDescription: String {
        switch currentMode {
        case .migration:
            return "Check for missing transcripts and summaries, import legacy files, view database information, or clear all data."
        case .integrityCheck:
            return "Scan your database for missing relationships, orphaned files, and other data integrity issues."
        case .repair:
            return "Automatically repair the data integrity issues found during the scan to restore missing transcripts and summaries."
        }
    }
    
    
    // MARK: - Cleanup Functions
    
    // MARK: - Orphaned Audio Files Functions
    
    private func scanForOrphanedAudioFiles() async {
        await MainActor.run {
            let files = EnhancedFileManager.shared.findOrphanedAudioFiles(coordinator: appCoordinator)
            orphanedAudioFiles = files
            
            // Calculate total size
            totalOrphanedSize = files.reduce(0) { total, file in
                total + getFileSize(file)
            }
        }
    }
    
    private func performOrphanedFilesCleanup() async {
        await MainActor.run {
            let results = EnhancedFileManager.shared.cleanupOrphanedAudioFiles(
                coordinator: appCoordinator,
                dryRun: false
            )
            orphanedFilesResults = results
            showingOrphanedFilesResults = true
        }
    }
    
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
    
    private func removeOrphanedImportFiles() async {
        print("🧹 Starting removal of orphaned import files...")
        
        let allRecordings = appCoordinator.coreDataManager.getAllRecordings()
        var removedCount = 0
        
        for recording in allRecordings {
            // Check if this is an orphaned import file
            if let recordingName = recording.recordingName,
               recordingName.hasPrefix("importedfile-") {
                
                // Check if it has no transcript and no summary
                let hasTranscript = recording.transcript != nil
                let hasSummary = recording.summary != nil
                
                if !hasTranscript && !hasSummary {
                    print("🗑️ Removing orphaned import file: \(recordingName)")
                    
                    // Delete from Core Data
                    if let recordingId = recording.id {
                        appCoordinator.coreDataManager.deleteRecording(id: recordingId)
                        removedCount += 1
                    }
                } else {
                    print("ℹ️ Keeping import file with data: \(recordingName) (has transcript: \(hasTranscript), has summary: \(hasSummary))")
                }
            }
        }
        
        print("✅ Removed \(removedCount) orphaned import files")
    }
    
    private func performCleanup() async {
        isPerformingCleanup = true
        
        do {
            let results = try await cleanupOrphanedData()
            await MainActor.run {
                self.cleanupResults = results
                self.isPerformingCleanup = false
            }
        } catch {
            await MainActor.run {
                self.isPerformingCleanup = false
                print("❌ Cleanup error: \(error)")
            }
        }
    }
    
    private func cleanupOrphanedData() async throws -> CleanupResults {
        print("🧹 Starting orphaned data cleanup...")
        
        // Get all recordings from Core Data
        let allRecordings = appCoordinator.coreDataManager.getAllRecordings()
        print("📁 Found \(allRecordings.count) recordings in Core Data")
        
        // Get all transcripts and summaries from Core Data
        let allTranscripts = appCoordinator.getAllTranscripts()
        let allSummaries = appCoordinator.getAllSummaries()
        
        print("📊 Found \(allSummaries.count) stored summaries and \(allTranscripts.count) stored transcripts")
        
        var orphanedSummaries = 0
        var orphanedTranscripts = 0
        var orphanedRecordings = 0
        var freedSpaceBytes: Int64 = 0
        
        // Create a set of valid recording IDs for quick lookup
        let validRecordingIds = Set(allRecordings.compactMap { $0.id })
        
        print("🔍 Valid recording IDs: \(validRecordingIds.count)")
        
        // Check for orphaned summaries
        for summary in allSummaries {
            let recordingId = summary.recordingId
            
            // Check if the recording ID exists in Core Data
            let hasValidID = recordingId != nil && validRecordingIds.contains(recordingId!)
            
            if !hasValidID {
                print("🗑️ Found orphaned summary for recording ID: \(recordingId?.uuidString ?? "nil")")
                print("   ID exists: \(hasValidID)")
                
                // Delete the orphaned summary
                if let summaryId = summary.id {
                    do {
                        try await appCoordinator.deleteSummary(id: summaryId)
                        orphanedSummaries += 1
                    } catch {
                        print("❌ Failed to delete orphaned summary: \(error)")
                    }
                } else {
                    print("❌ Cannot delete summary with nil ID")
                }
                
                // Calculate freed space (rough estimate)
                freedSpaceBytes += Int64(summary.summary?.count ?? 0 * 2) // Approximate UTF-8 bytes
            }
        }
        
        // Check for orphaned transcripts
        for transcript in allTranscripts {
            let recordingId = transcript.recordingId
            
            // Check if the recording ID exists in Core Data
            let hasValidID = recordingId != nil && validRecordingIds.contains(recordingId!)
            
            if !hasValidID {
                print("🗑️ Found orphaned transcript for recording ID: \(recordingId?.uuidString ?? "nil")")
                print("   ID exists: \(hasValidID)")
                
                // Delete the orphaned transcript
                appCoordinator.coreDataManager.deleteTranscript(id: transcript.id)
                orphanedTranscripts += 1
                
                // Calculate freed space
                let transcriptText = transcript.segments ?? ""
                freedSpaceBytes += Int64(transcriptText.count * 2) // Approximate UTF-8 bytes
            } else {
                // Log when we find a transcript that's actually valid
                print("✅ Found valid transcript for recording ID: \(recordingId?.uuidString ?? "nil")")
            }
        }
        
        // Check for transcripts where the recording file doesn't exist on disk
        for transcript in allTranscripts {
            guard let recordingId = transcript.recordingId,
                  let recording = appCoordinator.coreDataManager.getRecording(id: recordingId),
                  let recordingURLString = recording.recordingURL,
                  let recordingURL = URL(string: recordingURLString) else {
                continue
            }
            
            // Check if the recording file exists on disk
            let fileExists = FileManager.default.fileExists(atPath: recordingURL.path)
            
            // Check if the recording exists in Core Data
            let hasValidID = validRecordingIds.contains(recordingId)
            
            // Only remove if the file doesn't exist AND it's not in Core Data
            if !fileExists && !hasValidID {
                print("🗑️ Found transcript for non-existent recording file: \(recordingURL.lastPathComponent)")
                print("   File exists: \(fileExists), ID in Core Data: \(hasValidID)")
                
                // Delete the orphaned transcript
                appCoordinator.coreDataManager.deleteTranscript(id: transcript.id)
                orphanedTranscripts += 1
                
                // Calculate freed space
                let transcriptText = transcript.segments ?? ""
                freedSpaceBytes += Int64(transcriptText.count * 2) // Approximate UTF-8 bytes
            } else if !fileExists {
                // Log when file doesn't exist but recording is in Core Data
                print("⚠️  File not found on disk but recording exists in Core Data: \(recordingURL.lastPathComponent)")
                print("   File exists: \(fileExists), ID in Core Data: \(hasValidID)")
            }
        }
        
        // Check for orphaned recordings (recordings without files on disk and no data)
        print("🔍 Checking for orphaned recordings (missing audio files)...")
        for recording in allRecordings {
            guard let _ = recording.recordingURL,
                  let recordingURL = appCoordinator.coreDataManager.getAbsoluteURL(for: recording) else {
                print("⚠️ Recording has invalid URL: \(recording.recordingName ?? "Unknown")")
                continue
            }
            
            // Check if the audio file exists on disk
            let fileExists = FileManager.default.fileExists(atPath: recordingURL.path)
            
            if !fileExists {
                // Check if this recording has any associated transcripts or summaries
                let hasTranscript = recording.transcript != nil
                let hasSummary = recording.summary != nil
                
                if !hasTranscript && !hasSummary {
                    // Safe to delete - no transcript, no summary, and no file
                    print("🗑️ Found orphaned recording (no file, no transcript, no summary): \(recording.recordingName ?? "Unknown")")
                    print("   File path: \(recordingURL.path)")
                    
                    // Delete the orphaned recording
                    if let recordingId = recording.id {
                        appCoordinator.coreDataManager.deleteRecording(id: recordingId)
                        orphanedRecordings += 1
                        print("✅ Deleted orphaned recording: \(recording.recordingName ?? "Unknown")")
                    }
                } else {
                    // Keep the recording even if file is missing, because it has data
                    print("⚠️ Keeping recording with missing file (has transcript: \(hasTranscript), has summary: \(hasSummary)): \(recording.recordingName ?? "Unknown")")
                }
            }
        }
        
        let freedSpaceMB = Double(freedSpaceBytes) / (1024 * 1024)
        
        print("✅ Cleanup complete:")
        print("   • Removed \(orphanedSummaries) orphaned summaries")
        print("   • Removed \(orphanedTranscripts) orphaned transcripts")
        print("   • Removed \(orphanedRecordings) orphaned recordings")
        print("   • Freed \(String(format: "%.1f", freedSpaceMB)) MB of space")
        
        return CleanupResults(
            orphanedSummaries: orphanedSummaries,
            orphanedTranscripts: orphanedTranscripts,
            orphanedRecordings: orphanedRecordings,
            freedSpaceMB: freedSpaceMB
        )
    }
}

// MARK: - Supporting Structures

struct CleanupResults {
    let orphanedSummaries: Int
    let orphanedTranscripts: Int
    let orphanedRecordings: Int
    let freedSpaceMB: Double
}

// MARK: - Compact Debug Button Style

struct CompactDebugButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray6))
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}