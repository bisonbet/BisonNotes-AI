//
//  RecordingsView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import SafariServices

struct RecordingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var importManager = FileImportManager()
    @StateObject private var transcriptImportManager = TranscriptImportManager()
    @StateObject private var documentPickerCoordinator = DocumentPickerCoordinator()
    @StateObject private var textDocumentPickerCoordinator = DocumentPickerCoordinator()
    @ObservedObject private var processingManager = BackgroundProcessingManager.shared
    @State private var recordings: [AudioRecordingFile] = []
    @State private var showingRecordingsList = false
    @State private var showingBackgroundProcessing = false
    @State private var showingHelpDocumentation = false
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Help documentation link at the top
                HStack {
                    Spacer()
                    Button(action: {
                        showingHelpDocumentation = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "questionmark.circle")
                            Text("Help")
                        }
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.1))
                        )
                    }
                    .padding(.trailing)
                    .padding(.top, 8)
                }
                
                Spacer()
                
                VStack(spacing: 40) {
                    VStack(spacing: 20) {
                        Image("AppLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: min(geometry.size.height * 0.25, 200))
                            .frame(maxWidth: .infinity)
                            .shadow(color: .accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                        
                        Text("BisonNotes AI")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 16) {
                        if recorderVM.isRecording {
                            Text(recorderVM.formatTime(recorderVM.recordingTime))
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.accentColor)
                                .monospacedDigit()
                        }
                        
                        Button(action: {
                            if recorderVM.isRecording {
                                recorderVM.stopRecording()
                            } else {
                                recorderVM.startRecording()
                            }
                        }) {
                            HStack {
                                Image(systemName: recorderVM.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                    .font(.title)
                                Text(recorderVM.isRecording ? "Stop Recording" : "Start Recording")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(recorderVM.isRecording ? Color.red : Color.accentColor)
                                    .shadow(color: recorderVM.isRecording ? .red.opacity(0.3) : .accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                            )
                            .padding(.horizontal, 40)
                        }
                        .scaleEffect(recorderVM.isRecording ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: recorderVM.isRecording)
                        
                        Button(action: {
                            showingRecordingsList = true
                        }) {
                            HStack {
                                Image(systemName: "list.bullet")
                                    .font(.title3)
                                Text("View Recordings")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.accentColor)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.accentColor, lineWidth: 2)
                                    .background(Color.accentColor.opacity(0.1))
                            )
                            .padding(.horizontal, 40)
                        }
                        
                        Button(action: {
                            // Directly trigger document picker for audio files
                            documentPickerCoordinator.selectAudioFiles { urls in
                                if !urls.isEmpty {
                                    Task {
                                        await importManager.importAudioFiles(from: urls)
                                    }
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "plus.circle")
                                    .font(.title3)
                                Text("Import Audio Files")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.green)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.green, lineWidth: 2)
                                    .background(Color.green.opacity(0.1))
                            )
                            .padding(.horizontal, 40)
                        }

                        Button(action: {
                            // Trigger document picker for text files
                            textDocumentPickerCoordinator.selectTextFiles { urls in
                                if !urls.isEmpty {
                                    Task {
                                        await transcriptImportManager.importTranscriptFiles(from: urls)
                                    }
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .font(.title3)
                                Text("Import Transcripts")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.purple)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.purple, lineWidth: 2)
                                    .background(Color.purple.opacity(0.1))
                            )
                            .padding(.horizontal, 40)
                        }
                        
                        if recorderVM.isRecording {
                            VStack(spacing: 8) {
                                HStack {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 12, height: 12)
                                        .scaleEffect(recorderVM.isRecording ? 1.2 : 1.0)
                                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: recorderVM.isRecording)
                                    Text("Recording...")
                                        .foregroundColor(.secondary)
                                        .font(.subheadline)
                                }
                                
                                // Background recording indicator
                                if recorderVM.isRecording {
                                    HStack {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.caption)
                                        Text("Background recording enabled")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
            .sheet(isPresented: $showingRecordingsList) {
                RecordingsListView()
                    .environmentObject(recorderVM)
            }
            .sheet(isPresented: $documentPickerCoordinator.isShowingPicker) {
                AudioDocumentPicker(isPresented: $documentPickerCoordinator.isShowingPicker, coordinator: documentPickerCoordinator)
            }
            .sheet(isPresented: $textDocumentPickerCoordinator.isShowingPicker) {
                TextDocumentPicker(isPresented: $textDocumentPickerCoordinator.isShowingPicker, coordinator: textDocumentPickerCoordinator)
            }
            .sheet(isPresented: $showingBackgroundProcessing) {
                BackgroundProcessingView()
            }
            .sheet(isPresented: $showingHelpDocumentation) {
                if let url = URL(string: "https://www.bisonnetworking.com/bisonnotes-ai/") {
                    SafariView(url: url)
                }
            }
            .alert("Transcript Import Results", isPresented: $transcriptImportManager.showingImportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                if let results = transcriptImportManager.importResults {
                    Text(results.summary)
                }
            }
        }
    }
    
    
    
    private var backgroundProcessingIndicator: some View {
        Button(action: {
            showingBackgroundProcessing = true
        }) {
            HStack {
                Image(systemName: "gear.circle.fill")
                    .font(.title3)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background Processing")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    let activeJobs = processingManager.activeJobs.filter { $0.status == .processing }.count
                    let completedJobs = processingManager.activeJobs.filter { $0.status == .completed }.count
                    Text("\(activeJobs) active, \(completedJobs) completed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal, 40)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Safari View Wrapper
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let safariVC = SFSafariViewController(url: url)
        safariVC.preferredBarTintColor = UIColor.systemBackground
        safariVC.preferredControlTintColor = UIColor.systemBlue
        safariVC.dismissButtonStyle = .close
        return safariVC
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // No updates needed
    }
}