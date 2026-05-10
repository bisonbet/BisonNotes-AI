//
//  DocumentExportPicker.swift
//  BisonNotes AI
//
//  UIViewControllerRepresentable wrapping UIDocumentPickerViewController for exporting files.
//  Used to archive audio recordings to iCloud Drive through the system
//  document picker. The archive service rejects non-iCloud destinations.
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    let onCompletion: (Bool, [URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Bool, [URL]) -> Void

        init(onCompletion: @escaping (Bool, [URL]) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(true, urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(false, [])
        }
    }
}
