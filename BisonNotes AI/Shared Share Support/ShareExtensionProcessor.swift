//
//  ShareExtensionProcessor.swift
//  Shared Share Support
//
//  Cross-platform Share extension processing. The platform view controllers
//  only present the extension and request that the host app open.
//

import Foundation
import UniformTypeIdentifiers
import os

enum ShareExtensionContract {
    static let appGroupIdentifier = "group.bisonnotesai.shared"
    static let inboxFolderName = "ShareInbox"
    static let tokenFileName = ".share-import-token"
    static let darwinNotificationName = "com.bisonnotesai.shareExtensionDidSaveFile"
    static let importURLScheme = "bisonnotes"
    static let importURLHost = "share-import"

    static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "caf", "aiff", "aif",
        "txt", "text", "md", "markdown", "pdf", "doc", "docx"
    ]

    private static let preferredTypeIdentifiers = [
        "com.apple.m4a-audio",
        UTType.mpeg4Audio.identifier,
        UTType.mp3.identifier,
        UTType.wav.identifier,
        UTType.audio.identifier,
        "com.apple.coreaudio-format",
        "public.aiff-audio",
        UTType.pdf.identifier,
        UTType.plainText.identifier,
        "net.daringfireball.markdown",
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.doc",
        UTType.text.identifier
    ]

    static func bestTypeIdentifier(for provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers

        if let exactMatch = preferredTypeIdentifiers.first(where: registered.contains) {
            return exactMatch
        }

        if let conformingType = preferredTypeIdentifiers.first(
            where: provider.hasItemConformingToTypeIdentifier
        ) {
            return conformingType
        }

        if let first = registered.first {
            NSLog("📎 Share Extension: using fallback type: \(first)")
            return first
        }

        return nil
    }

    static func importURL(for token: String) -> URL? {
        var components = URLComponents()
        components.scheme = importURLScheme
        components.host = importURLHost
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    static func destinationFileName(
        sourceURL: URL,
        providerSuggestedName: String?,
        typeIdentifier: String
    ) -> String? {
        var sourceName = sourceURL.lastPathComponent
        var fileExtension = sourceURL.pathExtension.lowercased()

        if fileExtension.isEmpty,
           let suggestedName = providerSuggestedName,
           !suggestedName.isEmpty {
            sourceName = URL(fileURLWithPath: suggestedName).lastPathComponent
            fileExtension = URL(fileURLWithPath: sourceName).pathExtension.lowercased()
        }

        if fileExtension.isEmpty,
           let inferredExtension = UTType(typeIdentifier)?.preferredFilenameExtension?.lowercased() {
            fileExtension = inferredExtension
            sourceName = sourceName.isEmpty
                ? "Shared File.\(inferredExtension)"
                : "\(sourceName).\(inferredExtension)"
        }

        guard supportedExtensions.contains(fileExtension) else {
            NSLog("📎 Share Extension: skipping unsupported extension: \(fileExtension)")
            return nil
        }

        let safeName = URL(fileURLWithPath: sourceName).lastPathComponent
        return "\(UUID().uuidString)_\(safeName)"
    }

    /// Compatibility overload for synchronous callers and existing tests.
    /// The asynchronous processor snapshots `suggestedName` before entering
    /// its Sendable file-representation callback instead of capturing the
    /// framework provider there.
    static func destinationFileName(
        sourceURL: URL,
        provider: NSItemProvider,
        typeIdentifier: String
    ) -> String? {
        destinationFileName(
            sourceURL: sourceURL,
            providerSuggestedName: provider.suggestedName,
            typeIdentifier: typeIdentifier
        )
    }
}

final class ShareExtensionProcessor {
    struct Result: Sendable {
        let savedFileCount: Int
        let importURL: URL?
    }

    func process(items: [NSExtensionItem], completion: @escaping (Result) -> Void) {
        NSLog("📎 Share Extension: processing \(items.count) extension item(s)")

        let group = DispatchGroup()
        let savedFileCount = OSAllocatedUnfairLock(initialState: 0)

        for item in items {
            let attachments = item.attachments ?? []
            NSLog("📎 Share Extension: item has \(attachments.count) attachment(s)")

            for provider in attachments {
                NSLog("📎 Share Extension: provider types: \(provider.registeredTypeIdentifiers)")

                guard let typeIdentifier = ShareExtensionContract.bestTypeIdentifier(for: provider) else {
                    NSLog("📎 Share Extension: no usable type identifier for provider")
                    continue
                }

                let providerSuggestedName = provider.suggestedName

                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    if let error {
                        NSLog("❌ Share Extension: loadFileRepresentation failed: \(error.localizedDescription)")
                        group.leave()
                        return
                    }

                    guard let url else {
                        NSLog("❌ Share Extension: loadFileRepresentation returned nil URL")
                        group.leave()
                        return
                    }

                    guard Self.saveToSharedContainer(
                        sourceURL: url,
                        providerSuggestedName: providerSuggestedName,
                        typeIdentifier: typeIdentifier
                    ) else {
                        group.leave()
                        return
                    }

                    savedFileCount.withLock { $0 += 1 }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            let finalCount = savedFileCount.withLock { $0 }

            guard finalCount > 0, let token = Self.createImportToken() else {
                NSLog("📎 Share Extension: done, saved \(finalCount) file(s)")
                completion(Result(savedFileCount: finalCount, importURL: nil))
                return
            }

            let importURL = ShareExtensionContract.importURL(for: token)
            NSLog("📎 Share Extension: done, saved \(finalCount) file(s)")
            completion(Result(savedFileCount: finalCount, importURL: importURL))
        }
    }

    static func postDarwinNotification() {
        let name = ShareExtensionContract.darwinNotificationName as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
    }

    private static func saveToSharedContainer(
        sourceURL: URL,
        providerSuggestedName: String?,
        typeIdentifier: String
    ) -> Bool {
        guard let destinationName = ShareExtensionContract.destinationFileName(
            sourceURL: sourceURL,
            providerSuggestedName: providerSuggestedName,
            typeIdentifier: typeIdentifier
        ) else {
            return false
        }

        guard let inboxURL = sharedInboxURL() else {
            return false
        }

        let destinationURL = inboxURL.appendingPathComponent(destinationName, isDirectory: false)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            applyFileProtection(to: destinationURL)
            NSLog("✅ Share Extension: saved file with extension: \(destinationURL.pathExtension)")
            return true
        } catch {
            NSLog("❌ Share Extension: copy failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func createImportToken() -> String? {
        guard let inboxURL = sharedInboxURL() else {
            return nil
        }

        do {
            let token = UUID().uuidString
            guard let tokenData = token.data(using: .utf8) else {
                return nil
            }

            let tokenURL = inboxURL.appendingPathComponent(
                ShareExtensionContract.tokenFileName,
                isDirectory: false
            )
            try tokenData.write(to: tokenURL, options: .atomic)
            applyFileProtection(to: tokenURL)
            return token
        } catch {
            NSLog("❌ Share Extension: cannot create import token: \(error)")
            return nil
        }
    }

    private static func sharedInboxURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareExtensionContract.appGroupIdentifier
        ) else {
            NSLog("❌ Share Extension: App Group container is unavailable")
            return nil
        }

        let inboxURL = containerURL.appendingPathComponent(
            ShareExtensionContract.inboxFolderName,
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(
                at: inboxURL,
                withIntermediateDirectories: true
            )
            return inboxURL
        } catch {
            NSLog("❌ Share Extension: cannot create ShareInbox: \(error)")
            return nil
        }
    }

    private static func applyFileProtection(to url: URL) {
#if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }
}
