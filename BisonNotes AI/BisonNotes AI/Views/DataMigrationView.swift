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
            
            // Legacy migration (for old data format)
            Button(action: {
                Task {
                    await migrationManager.performDataMigration()
                }
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Import Legacy Files")
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
            
            // iCloud Recovery
            Button(action: {
                Task {
                    // Initialize the migration manager with iCloud sync managers
                    migrationManager.setCloudSyncManagers(legacy: legacyiCloudManager)
                    
                    let results = await migrationManager.recoverDataFromiCloud()
                    // Handle recovery results
                    print("📥 Recovery completed: \(results.transcripts) transcripts, \(results.summaries) summaries")
                    if !results.errors.isEmpty {
                        print("⚠️ Recovery errors: \(results.errors.joined(separator: ", "))")
                    }
                }
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
}