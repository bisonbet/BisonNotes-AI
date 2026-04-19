//
//  ArchiveConfirmationView.swift
//  BisonNotes AI
//
//  Confirmation sheet shown before archiving recordings.
//  Displays selection summary and options for local file removal.
//

import SwiftUI

struct ArchiveConfirmationView: View {
    let recordingCount: Int
    let totalSize: Int64
    let recordingNames: [String]
    @Binding var removeLocal: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)

                    Text("Archive \(recordingCount) Recording\(recordingCount == 1 ? "" : "s")")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(fileSizeString)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)

                // Recording list preview (up to 5)
                if !recordingNames.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recordingNames.prefix(5), id: \.self) { name in
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                                Text(name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                        }
                        if recordingNames.count > 5 {
                            Text("and \(recordingNames.count - 5) more...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 22)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                    .padding(.horizontal)
                }

                // Options
                VStack(spacing: 12) {
                    Toggle(isOn: $removeLocal) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remove local audio after export")
                                .font(.subheadline)
                            Text("Transcripts and summaries will be kept")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                }
                .padding(.horizontal)

                if removeLocal {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("You'll need to re-import audio files to play them again")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal)
                }

                Spacer()

                // Actions
                VStack(spacing: 12) {
                    Button(action: onConfirm) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export to Files")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.accentColor)
                        )
                    }

                    Button(action: onCancel) {
                        Text("Cancel")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .navigationBarHidden(true)
        }
    }

    private var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}
