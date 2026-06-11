//
//  EnhancedDeleteDialog.swift
//  Audio Journal
//
//  Enhanced deletion confirmation dialog with file relationship information
//

import SwiftUI

struct EnhancedDeleteDialog: View {
    let recording: AudioRecordingFile
    let relationships: FileRelationships
    @Binding var preserveSummary: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)

                        Text("Delete Recording")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)

                        Text("Are you sure you want to delete '\(recording.name)'?")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("File Status")
                            .font(.headline)
                            .foregroundColor(.primary)

                        VStack(spacing: 12) {
                            FileStatusRow(
                                icon: "waveform",
                                title: "Recording",
                                status: relationships.hasRecording ? "Available" : "Not available",
                                color: relationships.hasRecording ? .green : .gray
                            )

                            FileStatusRow(
                                icon: "text.quote",
                                title: "Transcript",
                                status: relationships.transcriptExists ? "Available" : "Not available",
                                color: relationships.transcriptExists ? .blue : .gray
                            )

                            FileStatusRow(
                                icon: "doc.text",
                                title: "Summary",
                                status: relationships.summaryExists ? "Available" : "Not available",
                                color: relationships.summaryExists ? .purple : .gray
                            )
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if relationships.summaryExists {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Deletion Options")
                                .font(.headline)
                                .foregroundColor(.primary)

                            VStack(alignment: .leading, spacing: 10) {
                                deletionOptionRow(
                                    title: "Preserve Summary",
                                    subtitle: "Keep the summary even after deleting the recording",
                                    isSelected: preserveSummary,
                                    selectedColor: .green
                                ) {
                                    preserveSummary = true
                                }

                                deletionOptionRow(
                                    title: "Delete Everything",
                                    subtitle: "Delete recording, transcript, summary, and any notes or attached files",
                                    isSelected: !preserveSummary,
                                    selectedColor: .red
                                ) {
                                    preserveSummary = false
                                }
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    if relationships.summaryExists && preserveSummary {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("The summary will be preserved and can be accessed later, even without the original recording.")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack(spacing: 12) {
                        Button(action: onConfirm) {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("Delete Recording")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        Button(action: onCancel) {
                            Text("Cancel")
                                .font(.headline)
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Delete Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
        .onAppear {
            // Set default preserve summary option
            preserveSummary = relationships.summaryExists
            AppLog.shared.fileManagement("EnhancedDeleteDialog rendering: hasRecording=\(relationships.hasRecording), hasTranscript=\(relationships.transcriptExists), hasSummary=\(relationships.summaryExists), preserveSummary=\(preserveSummary)", level: .debug)
        }
    }

    private func deletionOptionRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        selectedColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? selectedColor : .gray)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

struct FileStatusRow: View {
    let icon: String
    let title: String
    let status: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }
}

#Preview {
    let sampleRelationships = FileRelationships(
        recordingURL: URL(string: "file:///sample.m4a"),
        recordingName: "Sample Recording",
        recordingDate: Date(),
        transcriptExists: true,
        summaryExists: true,
        iCloudSynced: false
    )

    let sampleRecording = AudioRecordingFile(
        url: URL(string: "file:///sample.m4a")!,
        name: "Sample Recording",
        date: Date(),
        duration: 120.0,
        locationData: nil
    )

    EnhancedDeleteDialog(
        recording: sampleRecording,
        relationships: sampleRelationships,
        preserveSummary: .constant(true),
        onConfirm: {},
        onCancel: {}
    )
}
