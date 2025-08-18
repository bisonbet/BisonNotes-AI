//
//  RecordingsView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var importManager = FileImportManager()
    @StateObject private var documentPickerCoordinator = DocumentPickerCoordinator()
    @ObservedObject private var processingManager = BackgroundProcessingManager.shared
    @State private var recordings: [AudioRecordingFile] = []
    @State private var showingRecordingsList = false
    @State private var showingBackgroundProcessing = false
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
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
                        
                        // Watch connection status indicator
                        watchConnectionStatusView
                        
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
            .sheet(isPresented: $showingBackgroundProcessing) {
                BackgroundProcessingView()
            }
        }
    }
    
    // MARK: - Watch Connection Status View
    
    @ViewBuilder
    private var watchConnectionStatusView: some View {
        if recorderVM.watchConnectionState != .disconnected {
            let connectionState = recorderVM.watchConnectionState
            HStack {
                // Watch connection icon
                Image(systemName: connectionState.sfSymbolName)
                    .font(.subheadline)
                    .foregroundColor(connectionColor(for: connectionState))
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Apple Watch")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        // Recording source indicator
                        if recorderVM.isWatchInitiatedRecording {
                            Image(systemName: "applewatch")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Text(connectionState.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Battery level if available
                        if let batteryLevel = recorderVM.watchBatteryLevel {
                            HStack(spacing: 2) {
                                Image(systemName: batteryIcon(for: batteryLevel))
                                    .font(.caption2)
                                    .foregroundColor(batteryColor(for: batteryLevel))
                                Text("\(Int(batteryLevel * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Audio transfer indicator
                        if recorderVM.isReceivingWatchAudio == true {
                            HStack(spacing: 2) {
                                Image(systemName: "waveform.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text("Receiving")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
                
                Spacer()
                
                // Connection status dot
                Circle()
                    .fill(connectionColor(for: connectionState))
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(connectionColor(for: connectionState).opacity(0.1))
                    .stroke(connectionColor(for: connectionState).opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 40)
        }
    }
    
    // MARK: - Helper Methods for Watch Status
    
    private func connectionColor(for state: WatchConnectionState) -> Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        case .phoneAppInactive, .watchAppInactive:
            return .yellow
        }
    }
    
    private func batteryIcon(for level: Float) -> String {
        switch level {
        case 0.0..<0.1:
            return "battery.0"
        case 0.1..<0.25:
            return "battery.25"
        case 0.25..<0.75:
            return "battery.50"
        case 0.75..<1.0:
            return "battery.75"
        default:
            return "battery.100"
        }
    }
    
    private func batteryColor(for level: Float) -> Color {
        if level < 0.2 {
            return .red
        } else if level < 0.5 {
            return .orange
        } else {
            return .green
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