//
//  DocumentPickerCoordinator.swift
//  Audio Journal
//
//  Handles document picker for audio file import
//

import Foundation
import UIKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document Picker Coordinator

class DocumentPickerCoordinator: NSObject, ObservableObject {
    @Published var selectedURLs: [URL] = []
    @Published var isShowingPicker = false

    private var completionHandler: (([URL]) -> Void)?

    func selectAudioFiles(completion: @escaping ([URL]) -> Void) {
        self.completionHandler = completion
        self.isShowingPicker = true
    }

    func selectTextFiles(completion: @escaping ([URL]) -> Void) {
        self.completionHandler = completion
        self.isShowingPicker = true
    }

    func handleSelectedURLs(_ urls: [URL]) {
        selectedURLs = urls
        completionHandler?(urls)
        completionHandler = nil
        isShowingPicker = false
    }
}

// MARK: - Document Picker View Controller

class AudioDocumentPickerViewController: UIDocumentPickerViewController {
    private let coordinator: DocumentPickerCoordinator
    
    init(coordinator: DocumentPickerCoordinator) {
        self.coordinator = coordinator
        
        // Create supported audio types
        var supportedTypes: [UTType] = [UTType.audio]
        
        // Add specific audio formats if available
        if let m4aType = UTType(filenameExtension: "m4a") {
            supportedTypes.append(m4aType)
        }
        if let mp3Type = UTType(filenameExtension: "mp3") {
            supportedTypes.append(mp3Type)
        }
        if let wavType = UTType(filenameExtension: "wav") {
            supportedTypes.append(wavType)
        }
        
        super.init(forOpeningContentTypes: supportedTypes, asCopy: true)
        
        self.delegate = coordinator
        self.allowsMultipleSelection = true
        self.shouldShowFileExtensions = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Document Picker Delegate

extension DocumentPickerCoordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Handle the selected URLs
        handleSelectedURLs(urls)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Handle cancellation
        handleSelectedURLs([])
    }
}

// MARK: - SwiftUI Document Picker

struct AudioDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let coordinator: DocumentPickerCoordinator

    func makeUIViewController(context: Context) -> AudioDocumentPickerViewController {
        return AudioDocumentPickerViewController(coordinator: coordinator)
    }

    func updateUIViewController(_ uiViewController: AudioDocumentPickerViewController, context: Context) {
        // No updates needed
    }
}

// MARK: - Text Document Picker View Controller

class TextDocumentPickerViewController: UIDocumentPickerViewController {
    private let coordinator: DocumentPickerCoordinator

    init(coordinator: DocumentPickerCoordinator) {
        self.coordinator = coordinator

        // Create supported text and document types
        var supportedTypes: [UTType] = [
            UTType.plainText,
            UTType.text,
            UTType.pdf  // Add PDF support
        ]

        // Add specific text formats if available
        if let txtType = UTType(filenameExtension: "txt") {
            supportedTypes.append(txtType)
        }
        if let mdType = UTType(filenameExtension: "md") {
            supportedTypes.append(mdType)
        }
        if let markdownType = UTType(filenameExtension: "markdown") {
            supportedTypes.append(markdownType)
        }

        // Add Word document types
        // DOCX - Office Open XML Document
        if let docxType = UTType(filenameExtension: "docx") {
            supportedTypes.append(docxType)
        }
        // Also try the standard Microsoft Word type
        if let wordType = UTType(importedAs: "org.openxmlformats.wordprocessingml.document") {
            supportedTypes.append(wordType)
        }
        // Legacy DOC format (limited support - will show warning)
        if let docType = UTType(filenameExtension: "doc") {
            supportedTypes.append(docType)
        }

        super.init(forOpeningContentTypes: supportedTypes, asCopy: true)

        self.delegate = coordinator
        self.allowsMultipleSelection = true
        self.shouldShowFileExtensions = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - SwiftUI Text Document Picker

struct TextDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let coordinator: DocumentPickerCoordinator

    func makeUIViewController(context: Context) -> TextDocumentPickerViewController {
        return TextDocumentPickerViewController(coordinator: coordinator)
    }

    func updateUIViewController(_ uiViewController: TextDocumentPickerViewController, context: Context) {
        // No updates needed
    }
} 