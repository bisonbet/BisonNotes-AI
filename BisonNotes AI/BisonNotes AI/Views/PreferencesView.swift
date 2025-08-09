//
//  PreferencesView.swift
//  BisonNotes AI
//
//  Created by Claude Code on 8/8/25.
//

import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var userPreferences = UserPreferences.shared
    @State private var showingTimeFormatExample = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    timeFormatSection
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferences")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text("Customize how BisonNotes AI displays information")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var timeFormatSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack {
                Image(systemName: "clock")
                    .font(.headline)
                    .foregroundColor(.blue)
                Text("Time Format")
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            
            // Description
            Text("Choose how time is displayed in summaries, transcripts, and recording lists")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            // Time format options
            VStack(spacing: 12) {
                ForEach(TimeFormat.allCases) { format in
                    timeFormatOption(format: format)
                }
            }
            
            // Example preview section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Preview")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button(action: {
                        showingTimeFormatExample.toggle()
                    }) {
                        HStack(spacing: 4) {
                            Text(showingTimeFormatExample ? "Hide" : "Show")
                            Image(systemName: showingTimeFormatExample ? "chevron.up" : "chevron.down")
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }
                
                if showingTimeFormatExample {
                    examplePreview
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.systemGray5), lineWidth: 0.5)
                )
        )
    }
    
    private func timeFormatOption(format: TimeFormat) -> some View {
        Button(action: {
            userPreferences.timeFormat = format
        }) {
            HStack(spacing: 16) {
                // Selection indicator
                Image(systemName: userPreferences.timeFormat == format ? "largecircle.fill.circle" : "circle")
                    .font(.title2)
                    .foregroundColor(userPreferences.timeFormat == format ? .blue : .gray)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Format name
                    Text(format.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    // Format description
                    Text(format.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Live example
                    Text("Example: \(userPreferences.formatDate(Date(), dateStyle: .medium, includeTime: true))")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .opacity(userPreferences.timeFormat == format ? 1.0 : 0.6)
                }
                
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(userPreferences.timeFormat == format ? Color.blue.opacity(0.1) : Color(.systemGray6))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var examplePreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Example dates
            let sampleDate1 = Date()
            let sampleDate2 = Calendar.current.date(byAdding: .hour, value: -3, to: Date()) ?? Date()
            let sampleDate3 = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Summary Header:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                Text(userPreferences.formatFullDateTime(sampleDate1))
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray6))
                    )
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Recording List:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(userPreferences.formatMediumDateTime(sampleDate1))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("• 5:23")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(userPreferences.formatMediumDateTime(sampleDate2))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("• 12:45")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(userPreferences.formatMediumDateTime(sampleDate3))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("• 8:12")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray6))
                )
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Metadata:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                Text("Generation Time: \(userPreferences.formatShortDateTime(sampleDate2))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray6))
                    )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5).opacity(0.5))
        )
    }
}