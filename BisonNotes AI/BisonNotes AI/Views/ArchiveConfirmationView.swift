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
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
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

                        Text("Archive copies are currently limited to iCloud Drive so the app can reliably track, restore, and clean them up.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.top, 8)

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
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Toggle(isOn: $removeLocal) {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.badge.minus")
                                .font(.headline)
                                .foregroundColor(.accentColor)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Remove local audio after export")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Transcripts and summaries will be kept")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if removeLocal {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Use the download button to restore audio later")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    VStack(spacing: 12) {
                        Button(action: onConfirm) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Choose iCloud Location")
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        Button(action: onCancel) {
                            Text("Cancel")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
        }
    }

    private var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}
