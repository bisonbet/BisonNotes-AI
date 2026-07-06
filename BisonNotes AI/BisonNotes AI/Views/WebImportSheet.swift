//
//  WebImportSheet.swift
//  BisonNotes AI
//
//  Sheet for importing recordings and transcripts from web links.
//

import SwiftUI

struct WebImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var webImportManager: WebImportManager
    @ObservedObject var fileImportManager: FileImportManager
    @ObservedObject var transcriptImportManager: TranscriptImportManager
    @State private var urlText = ""
    @State private var importKind: WebImportKind = .automatic
    @State private var pastedTranscriptText = ""

    private var canImport: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !webImportManager.isImporting
            && !fileImportManager.isImporting
            && !transcriptImportManager.isImporting
    }

    private var canImportPastedTranscript: Bool {
        !pastedTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !webImportManager.isImporting
            && !transcriptImportManager.isImporting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/meeting.m4a", text: $urlText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("Import As", selection: $importKind) {
                        ForEach(WebImportKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                }

                if webImportManager.isImporting {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(webImportManager.currentlyImporting)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let recovery = webImportManager.youtubeRecovery {
                    Section("YouTube Transcript") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Automatic captions were blocked", systemImage: "exclamationmark.triangle")
                                .font(.headline)

                            Text(webImportManager.importMessage)
                                .foregroundColor(.secondary)

                            Text("""
                            Open the video, show the transcript in YouTube, copy the transcript text, \
                            then paste it below. You can also import a VTT, SRT, or TXT transcript file \
                            from the Recordings screen.
                            """)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)

                        Button {
                            openURL(recovery.videoURL)
                        } label: {
                            Label("Open YouTube Video", systemImage: "arrow.up.right.square")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Paste Transcript")
                                .font(.headline)

                            TextEditor(text: $pastedTranscriptText)
                                .frame(minHeight: 140)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.25))
                                )
                        }
                        .padding(.vertical, 4)

                        if transcriptImportManager.isImporting {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(transcriptImportManager.currentlyImporting)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button {
                            importPastedTranscript(recovery)
                        } label: {
                            Label("Import Pasted Transcript", systemImage: "doc.text")
                        }
                        .disabled(!canImportPastedTranscript)
                    }
                }
            }
            .navigationTitle("Import From Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(webImportManager.isImporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        submitImport()
                    }
                    .disabled(!canImport)
                }
            }
            .alert("Import Link Failed", isPresented: $webImportManager.showingImportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(webImportManager.importMessage)
            }
            .onChange(of: urlText) { _, _ in
                webImportManager.clearYouTubeRecovery()
                pastedTranscriptText = ""
            }
        }
    }

    private func submitImport() {
        Task {
            await webImportManager.importFromURLString(
                urlText,
                importKind: importKind,
                fileImportManager: fileImportManager,
                transcriptImportManager: transcriptImportManager
            )

            if webImportManager.lastImportSucceeded {
                dismiss()
            }
        }
    }

    private func importPastedTranscript(_ recovery: YouTubeImportRecovery) {
        let rawText = pastedTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return }

        let cleanedText = TranscriptCaptionTextCleaner.plainText(from: rawText)
        let transcriptText = cleanedText.isEmpty ? rawText : cleanedText

        Task {
            await transcriptImportManager.importTranscriptTextItems([
                TranscriptTextImportItem(
                    text: transcriptText,
                    name: recovery.transcriptName
                )
            ])

            if (transcriptImportManager.importResults?.successful ?? 0) > 0 {
                webImportManager.clearYouTubeRecovery()
                dismiss()
            } else {
                webImportManager.importMessage = "The pasted transcript could not be imported."
                webImportManager.showingImportAlert = true
            }
        }
    }
}
