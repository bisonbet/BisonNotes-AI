//
//  BackgroundProcessingView.swift
//  Audio Journal
//
//  Background processing status and job management view
//

import SwiftUI

struct BackgroundProcessingView: View {
    @ObservedObject private var processingManager = BackgroundProcessingManager.shared
    @State private var showingJobDetails = false
    @State private var selectedJob: ProcessingJob?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header with overall status
                headerSection
                
                // Active jobs list
                if !processingManager.activeJobs.isEmpty {
                    jobsListSection
                } else {
                    emptyStateSection
                }
                
                Spacer()
            }
            .navigationTitle("Background Processing")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Cleanup Completed Jobs") {
                            Task {
                                await processingManager.cleanupCompletedJobs()
                            }
                        }
                        
                        Button("Cancel All Jobs") {
                            Task {
                                await processingManager.cancelAllJobs()
                            }
                        }
                        
                        Divider()
                        
                        Button("Clear All Jobs", role: .destructive) {
                            Task {
                                await processingManager.clearAllJobs()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingJobDetails) {
                if let job = selectedJob {
                    JobDetailView(job: job)
                }
            }
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            // Overall status card
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: statusIcon)
                        .font(.title2)
                        .foregroundColor(statusColor)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Processing Status")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text(processingManager.processingStatus.displayName)
                            .font(.subheadline)
                            .foregroundColor(statusColor)
                    }
                    
                    Spacer()
                    
                    if processingManager.processingStatus == .processing {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                
                // Progress bar for overall processing
                if processingManager.processingStatus == .processing {
                    ProgressView(value: overallProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .padding(.top, 4)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
            .padding(.horizontal)
            
            // Quick stats
            HStack(spacing: 20) {
                StatCard(
                    title: "Active Jobs",
                    value: "\(processingManager.activeJobs.filter { $0.status == .processing }.count)",
                    icon: "clock.fill",
                    color: .blue
                )
                
                StatCard(
                    title: "Completed",
                    value: "\(processingManager.activeJobs.filter { $0.status == .completed }.count)",
                    icon: "checkmark.circle.fill",
                    color: .green
                )
                
                StatCard(
                    title: "Failed",
                    value: "\(processingManager.activeJobs.filter { $0.status.isError }.count)",
                    icon: "exclamationmark.triangle.fill",
                    color: .red
                )
            }
            .padding(.horizontal)
        }
        .padding(.top)
    }
    
    private var jobsListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Jobs")
                .font(.headline)
                .padding(.horizontal)
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(processingManager.activeJobs) { job in
                        JobCard(job: job) {
                            selectedJob = job
                            showingJobDetails = true
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    
    private var emptyStateSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("No Active Jobs")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            Text("All processing jobs have been completed or there are no pending jobs.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var statusIcon: String {
        switch processingManager.processingStatus {
        case .queued:
            return "clock"
        case .processing:
            return "gear"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
    
    private var statusColor: Color {
        switch processingManager.processingStatus {
        case .queued:
            return .orange
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
    
    private var overallProgress: Double {
        let completedJobs = processingManager.activeJobs.filter { $0.status == .completed }.count
        let totalJobs = processingManager.activeJobs.count
        return totalJobs > 0 ? Double(completedJobs) / Double(totalJobs) : 0.0
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }
}

struct JobCard: View {
    let job: ProcessingJob
    let onTap: () -> Void
    @State private var currentTime = Date()
    @State private var timer: Timer?
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.recordingName)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Text(job.type.displayName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    StatusBadge(status: convertJobStatus(job.status))
                }
                
                // Progress bar
                if job.status == .processing {
                    ProgressView(value: job.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                }
                
                // Time information
                HStack {
                    if job.status == .processing {
                        Text("Running: \(formatDuration(currentTime.timeIntervalSince(job.startTime)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .onAppear {
                                // Start timer to update running time
                                timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                                    currentTime = Date()
                                }
                            }
                            .onDisappear {
                                // Clean up timer when view disappears
                                timer?.invalidate()
                                timer = nil
                            }
                    } else if job.status == .completed, let completionTime = job.completionTime {
                        Text("Duration: \(formatDuration(completionTime.timeIntervalSince(job.startTime)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Started: \(job.startTime, style: .relative)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if job.status == .completed, let completionTime = job.completionTime {
                        Text("Completed: \(formatCompletionTime(completionTime))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Error message if failed
                if case .failed(let error) = job.status {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
    
    private func formatCompletionTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct StatusBadge: View {
    let status: ProcessingStatus
    
    var body: some View {
        Text(status.description)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(statusColor)
            )
    }
    
    private var statusColor: Color {
        switch status {
        case .notStarted:
            return .gray
        case .queued:
            return .orange
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }
}

struct JobDetailView: View {
    let job: ProcessingJob
    @Environment(\.dismiss) private var dismiss
    @State private var currentTime = Date()
    @State private var timer: Timer?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Job header
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.recordingName)
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text(job.type.displayName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    // Status and progress
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Status")
                            .font(.headline)
                        
                        HStack {
                            StatusBadge(status: convertJobStatus(job.status))
                            Spacer()
                        }
                        
                        if job.status == .processing {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Progress")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                ProgressView(value: job.progress)
                                    .progressViewStyle(LinearProgressViewStyle())
                                
                                Text("\(Int(job.progress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // Timing information
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Timing")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Started:")
                                Spacer()
                                Text(job.startTime, style: .time)
                            }
                            
                            if job.status == .processing {
                                HStack {
                                    Text("Running:")
                                    Spacer()
                                    Text(formatDuration(currentTime.timeIntervalSince(job.startTime)))
                                }
                                .onAppear {
                                    // Start timer to update running time
                                    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                                        currentTime = Date()
                                    }
                                }
                                .onDisappear {
                                    // Clean up timer when view disappears
                                    timer?.invalidate()
                                    timer = nil
                                }
                            } else if job.status == .completed, let completionTime = job.completionTime {
                                HStack {
                                    Text("Completed:")
                                    Spacer()
                                    Text(formatCompletionTime(completionTime))
                                }
                                
                                HStack {
                                    Text("Duration:")
                                    Spacer()
                                    Text(formatDuration(completionTime.timeIntervalSince(job.startTime)))
                                }
                            }
                        }
                        .font(.subheadline)
                    }
                    
                    // Chunk information
                    if let chunks = job.chunks, !chunks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("File Chunks")
                                .font(.headline)
                            
                            Text("Processing \(chunks.count) chunks")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Error details
                    if case .failed(let error) = job.status {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Error Details")
                                .font(.headline)
                            
                            Text(error)
                                .font(.body)
                                .foregroundColor(.red)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.red.opacity(0.1))
                                )
                        }
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Job Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
    
    private func formatCompletionTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Helper Functions

private func convertJobStatus(_ jobStatus: JobProcessingStatus) -> ProcessingStatus {
    switch jobStatus {
    case .queued:
        return .queued
    case .processing:
        return .processing
    case .completed:
        return .completed
    case .failed:
        return .failed
    }
}

#Preview {
    BackgroundProcessingView()
} 