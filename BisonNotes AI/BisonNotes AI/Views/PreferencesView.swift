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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    headerSection
                    timeFormatSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemGroupedBackground))
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Preferences")
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primary)

            Text("Customize how BisonNotes AI displays information")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var timeFormatSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(width: 30, height: 30)
                    .background(Color.blue.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                Text("Time Format")
                    .font(.headline)
                    .foregroundColor(.primary)
            }

            Text("Choose how time is displayed in summaries, transcripts, and recording lists")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(TimeFormat.allCases) { format in
                    timeFormatOption(format: format)
                }
            }

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
                        .foregroundColor(.accentColor)
                    }
                }

                if showingTimeFormatExample {
                    examplePreview
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func timeFormatOption(format: TimeFormat) -> some View {
        Button(action: {
            userPreferences.timeFormat = format
        }) {
            HStack(spacing: 14) {
                Image(systemName: format == .twelveHour ? "clock" : "clock.badge")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(width: 38, height: 38)
                    .background(Color.blue.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 4) {
                    Text(format.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(format.description)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Example: \(userPreferences.formatDate(Date(), dateStyle: .medium, includeTime: true))")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .opacity(userPreferences.timeFormat == format ? 1.0 : 0.6)
                }

                Spacer()

                Image(systemName: userPreferences.timeFormat == format ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(userPreferences.timeFormat == format ? .blue : .secondary)
            }
            .padding(14)
            .background(userPreferences.timeFormat == format ? Color.blue.opacity(0.12) : Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }

    private var examplePreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            let sampleDate1 = Date()
            let sampleDate2 = Calendar.current.date(byAdding: .hour, value: -3, to: Date()) ?? Date()
            let sampleDate3 = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()

            previewBlock(
                title: "Summary Header",
                value: userPreferences.formatFullDateTime(sampleDate1)
            )

            previewBlock(title: "Recording List") {
                VStack(alignment: .leading, spacing: 5) {
                    previewLine(userPreferences.formatMediumDateTime(sampleDate1), duration: "5:23")
                    previewLine(userPreferences.formatMediumDateTime(sampleDate2), duration: "12:45")
                    previewLine(userPreferences.formatMediumDateTime(sampleDate3), duration: "8:12")
                }
            }

            previewBlock(
                title: "Metadata",
                value: "Generation Time: \(userPreferences.formatShortDateTime(sampleDate2))"
            )
        }
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func previewBlock(title: String, value: String) -> some View {
        previewBlock(title: title) {
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
        }
    }

    private func previewBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func previewLine(_ dateText: String, duration: String) -> some View {
        HStack(spacing: 6) {
            Text(dateText)
            Text("- \(duration)")
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}
