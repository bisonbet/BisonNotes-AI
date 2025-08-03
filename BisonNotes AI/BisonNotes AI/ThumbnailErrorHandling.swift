//
//  ThumbnailErrorHandling.swift
//  Audio Journal
//
//  Shared utility for handling thumbnail generation errors
//

import Foundation

// MARK: - Thumbnail Error Detection

extension Error {
    var isThumbnailGenerationError: Bool {
        let errorDescription = self.localizedDescription
        let nsError = self as NSError
        
        return errorDescription.contains("QLThumbnailErrorDomain") || 
               errorDescription.contains("GSLibraryErrorDomain") ||
               errorDescription.contains("Generation not found") ||
               errorDescription.contains("_UIViewServiceErrorDomain") ||
               errorDescription.contains("Terminated=disconnect method") ||
               nsError.domain == "QLThumbnailErrorDomain" ||
               nsError.domain == "GSLibraryErrorDomain" ||
               nsError.domain == "_UIViewServiceErrorDomain" ||
               (nsError.domain == "QLThumbnailErrorDomain" && nsError.code == 102) ||
               (nsError.domain == "GSLibraryErrorDomain" && nsError.code == 3) ||
               (nsError.domain == "_UIViewServiceErrorDomain" && nsError.code == 1)
    }
} 