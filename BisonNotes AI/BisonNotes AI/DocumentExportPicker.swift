//
//  DocumentExportPicker.swift
//  BisonNotes AI
//
//  UIViewControllerRepresentable wrapping UIDocumentPickerViewController for exporting files.
//  Used to archive audio recordings to iCloud Drive, Dropbox, Google Drive, etc.
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    let onCompletion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Bool) -> Void

        init(onCompletion: @escaping (Bool) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(false)
        }
    }
}
