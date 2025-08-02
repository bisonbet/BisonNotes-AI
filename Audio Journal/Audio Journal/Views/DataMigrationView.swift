//
//  DataMigrationView.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import SwiftUI

struct DataMigrationView: View {
    @StateObject private var migrationManager = DataMigrationManager()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                
                Text("Data Migration")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("This will scan your audio files and organize them in the database with proper relationships between recordings, transcripts, and summaries.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                if migrationManager.migrationProgress > 0 {
                    VStack(spacing: 16) {
                        ProgressView(value: migrationManager.migrationProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                        
                        Text(migrationManager.migrationStatus)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                }
                
                VStack(spacing: 16) {
                    if !migrationManager.isCompleted {
                        Button(action: {
                            Task {
                                await migrationManager.performDataMigration()
                            }
                        }) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text("Start Migration")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.accentColor)
                            .cornerRadius(12)
                        }
                        .disabled(migrationManager.migrationProgress > 0 && !migrationManager.isCompleted)
                        
                        Button(action: {
                            Task {
                                await migrationManager.clearAllCoreData()
                            }
                        }) {
                            HStack {
                                Image(systemName: "trash.circle")
                                Text("Clear Database")
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
                        
                        Button(action: {
                            Task {
                                await migrationManager.debugCoreDataContents()
                            }
                        }) {
                            HStack {
                                Image(systemName: "info.circle")
                                Text("Debug Database")
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
                    } else {
                        Button("Done") {
                            dismiss()
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.green)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Migration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}