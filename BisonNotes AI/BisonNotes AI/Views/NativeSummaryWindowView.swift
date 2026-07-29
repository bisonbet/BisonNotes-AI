//
//  NativeSummaryWindowView.swift
//  BisonNotes AI
//

#if os(macOS)
import SwiftUI

/// Resolves a recording at window creation time so native macOS summaries can
/// live in independent, movable windows without copying Core Data objects into
/// the scene value used by `openWindow`.
struct NativeSummaryWindowView: View {
    let recordingID: UUID

    @EnvironmentObject private var appCoordinator: AppDataCoordinator

    var body: some View {
        Group {
            if let completeData = appCoordinator.getCompleteRecordingData(id: recordingID),
               let summary = completeData.summary {
                SummaryDetailView(
                    recording: RecordingFile(
                        url: appCoordinator.getAbsoluteURL(for: completeData.recording)
                            ?? URL(fileURLWithPath: completeData.recording.recordingURL ?? ""),
                        name: completeData.recording.recordingName ?? "Unknown",
                        date: completeData.recording.recordingDate ?? Date(),
                        duration: completeData.recording.duration,
                        locationData: appCoordinator.coreDataManager.getLocationData(for: completeData.recording)
                    ),
                    summaryData: summary
                )
            } else {
                ContentUnavailableView(
                    "Summary Not Available",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This summary may have been deleted or moved.")
                )
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}
#endif
