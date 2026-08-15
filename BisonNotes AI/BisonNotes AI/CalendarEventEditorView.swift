//
//  CalendarEventEditorView.swift
//  BisonNotes AI
//
//  Presents Apple's native event editor for Calendar integrations.
//

import SwiftUI
import EventKit

enum CalendarEventEditorResult: Equatable {
    case saved
    case canceled
    case deleted
    case failed(String)
}

enum SystemIntegrationSheet: Identifiable {
    case selection
    case calendar(CalendarEventDraft)

    var id: String {
        switch self {
        case .selection:
            return "selection"
        case .calendar(let draft):
            return "calendar-\(draft.id.uuidString)"
        }
    }
}

#if canImport(UIKit) && canImport(EventKitUI)
import UIKit
import EventKitUI

struct CalendarEventEditorView: UIViewControllerRepresentable {
    let draft: CalendarEventDraft
    let onCompletion: (CalendarEventEditorResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let viewController = EKEventEditViewController()
        viewController.eventStore = draft.eventStore
        viewController.event = draft.event
        viewController.editViewDelegate = context.coordinator
        return viewController
    }

    func updateUIViewController(_ viewController: EKEventEditViewController, context: Context) {
        // The event editor owns its form state after presentation.
    }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        private let onCompletion: (CalendarEventEditorResult) -> Void
        private var hasCompleted = false

        init(onCompletion: @escaping (CalendarEventEditorResult) -> Void) {
            self.onCompletion = onCompletion
        }

        func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            guard !hasCompleted else { return }
            hasCompleted = true

            let result: CalendarEventEditorResult
            switch action {
            case .saved:
                result = .saved
            case .deleted:
                result = .deleted
            case .canceled:
                result = .canceled
            @unknown default:
                result = .canceled
            }

            onCompletion(result)
        }
    }
}
#else

/// Native macOS has no UIKit event editor. Preserve the existing integration
/// behavior there while the iOS target uses EKEventEditViewController.
struct CalendarEventEditorView: View {
    let draft: CalendarEventDraft
    let onCompletion: (CalendarEventEditorResult) -> Void
    @State private var didAttemptSave = false

    var body: some View {
        ProgressView("Adding to Calendar…")
            .padding()
            .task {
                guard !didAttemptSave else { return }
                didAttemptSave = true

                do {
                    try draft.eventStore.save(draft.event, span: .thisEvent, commit: true)
                    onCompletion(.saved)
                } catch {
                    onCompletion(.failed(error.localizedDescription))
                }
            }
    }
}
#endif
