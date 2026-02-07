//
//  ShareViewController.swift
//  BisonNotes Share
//
//  Created by Tim Champ on 1/31/26.
//
//  Share Extension that receives files from Voice Memos, Files, and other apps
//  via the iOS share sheet. Copies shared files to the App Group container so
//  the main app can import them on next launch.
//

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let appGroupID = "group.bisonnotesai.shared"
    private let shareInboxFolder = "ShareInbox"

    /// File extensions the main app can import.
    private let supportedExtensions: Set<String> = [
        "m4a", "mp3", "wav", "caf", "aiff", "aif",
        "txt", "text", "md", "markdown", "pdf", "doc", "docx"
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        processSharedItems()
    }

    // MARK: - Process Shared Items

    private func processSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem],
              !extensionItems.isEmpty else {
            NSLog("📎 Share Extension: no extension items found")
            completeRequest()
            return
        }

        NSLog("📎 Share Extension: processing \(extensionItems.count) extension item(s)")

        let group = DispatchGroup()
        var processedCount = 0

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            NSLog("📎 Share Extension: item has \(attachments.count) attachment(s)")

            for provider in attachments {
                // Log what the provider actually offers so we can diagnose mismatches.
                NSLog("📎 Share Extension: provider types: \(provider.registeredTypeIdentifiers)")

                // Use the provider's own first registered type identifier to load the file.
                // This is more reliable than guessing specific UTIs.
                guard let typeID = bestTypeIdentifier(for: provider) else {
                    NSLog("📎 Share Extension: no usable type identifier for provider")
                    continue
                }

                NSLog("📎 Share Extension: loading file with type: \(typeID)")
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] url, error in
                    defer { group.leave() }
                    guard let self = self else { return }

                    if let error = error {
                        NSLog("❌ Share Extension: loadFileRepresentation failed: \(error.localizedDescription)")
                        return
                    }
                    guard let url = url else {
                        NSLog("❌ Share Extension: loadFileRepresentation returned nil URL")
                        return
                    }

                    NSLog("📎 Share Extension: received temp file: \(url.lastPathComponent)")

                    // Verify the file extension is one we support
                    let ext = url.pathExtension.lowercased()
                    guard self.supportedExtensions.contains(ext) else {
                        NSLog("📎 Share Extension: skipping unsupported extension: \(ext)")
                        return
                    }

                    if self.saveToSharedContainer(url: url) {
                        processedCount += 1
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            NSLog("📎 Share Extension: done, saved \(processedCount) file(s)")
            // Open the main app so it imports immediately instead of waiting for user to switch.
            self?.openMainApp {
                self?.completeRequest()
            }
        }
    }

    /// Picks the best type identifier to load the file representation.
    /// Prefers specific audio/document types, falls back to the first registered type.
    private func bestTypeIdentifier(for provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers

        // Preferred types in priority order
        let preferred = [
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

        // Try preferred types first (exact match in registered list)
        for type in preferred {
            if registered.contains(type) {
                return type
            }
        }

        // Try conformance check (e.g. provider has "com.apple.m4a-audio" which conforms to "public.audio")
        for type in preferred {
            if provider.hasItemConformingToTypeIdentifier(type) {
                return type
            }
        }

        // Last resort: use the provider's first registered type and hope loadFileRepresentation works
        if let first = registered.first {
            NSLog("📎 Share Extension: using fallback type: \(first)")
            return first
        }

        return nil
    }

    // MARK: - File Storage

    private func saveToSharedContainer(url: URL) -> Bool {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            NSLog("❌ Share Extension: containerURL is nil — is the App Group '\(appGroupID)' configured in Signing & Capabilities?")
            return false
        }

        let inboxURL = containerURL.appendingPathComponent(shareInboxFolder)

        do {
            try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        } catch {
            NSLog("❌ Share Extension: cannot create ShareInbox: \(error)")
            return false
        }

        // UUID prefix prevents filename collisions.
        let uniqueName = "\(UUID().uuidString)_\(url.lastPathComponent)"
        let destination = inboxURL.appendingPathComponent(uniqueName)

        do {
            try FileManager.default.copyItem(at: url, to: destination)
            NSLog("✅ Share Extension: saved \(url.lastPathComponent) → \(destination.lastPathComponent)")
            return true
        } catch {
            NSLog("❌ Share Extension: copy failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Open Main App

    /// Attempts to open the main app via its custom URL scheme so it imports
    /// shared files immediately.
    ///
    /// Strategy:
    /// 1. Access UIApplication.shared directly via ObjC runtime and call
    ///    the modern `open(_:options:completionHandler:)` with proper arg passing.
    /// 2. Fall back to the responder chain (in case direct access fails).
    /// 3. Post a Darwin notification (works when app is already backgrounded).
    /// 4. (Implicit) The main app scans the shared container on `didBecomeActive`.
    private func openMainApp(completion: @escaping () -> Void) {
        guard let url = URL(string: "bisonnotes://share-import") else {
            completion()
            return
        }

        // Tier 1: Direct access to UIApplication.shared via ObjC runtime.
        // This bypasses the responder chain which may not include UIApplication
        // in a share extension's view hierarchy.
        if openURLViaSharedApplication(url) {
            NSLog("📎 Share Extension: opened main app via UIApplication.shared")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion()
            }
            return
        }

        // Tier 2: Walk the responder chain as a fallback.
        if openURLViaResponderChain(url) {
            NSLog("📎 Share Extension: opened main app via responder chain")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion()
            }
            return
        }

        // Tier 3: Darwin notification for when the app is already running.
        postDarwinNotification()
        NSLog("📎 Share Extension: posted Darwin notification as fallback")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            completion()
        }
    }

    /// Accesses UIApplication.shared directly through the ObjC runtime
    /// (bypassing the responder chain) and calls open(_:options:completionHandler:)
    /// using method(for:) + unsafeBitCast for correct 3-argument invocation.
    private func openURLViaSharedApplication(_ url: URL) -> Bool {
        // UIApplication class is available in extensions; only .shared is
        // compile-time restricted, so we reach it through the runtime.
        guard let appClass = NSClassFromString("UIApplication") else {
            NSLog("📎 Share Extension: UIApplication class not found")
            return false
        }

        let sharedSel = NSSelectorFromString("sharedApplication")
        guard let unmanaged = (appClass as AnyObject).perform(sharedSel),
              let application = unmanaged.takeUnretainedValue() as? NSObject else {
            NSLog("📎 Share Extension: could not get UIApplication.shared")
            return false
        }

        let openSel = NSSelectorFromString("openURL:options:completionHandler:")
        guard application.responds(to: openSel) else {
            NSLog("📎 Share Extension: UIApplication does not respond to open:options:completionHandler:")
            return false
        }

        // Use method(for:) + unsafeBitCast to properly pass all 3 arguments.
        // perform(_:with:with:) only supports 2 args, leaving the third
        // (completionHandler) undefined — which can crash on ARM64.
        let imp = application.method(for: openSel)
        typealias OpenURLFunc = @convention(c) (NSObject, Selector, URL, NSDictionary, Any?) -> Void
        let openURL = unsafeBitCast(imp, to: OpenURLFunc.self)
        openURL(application, openSel, url, NSDictionary(), nil)
        return true
    }

    /// Walks the responder chain to find UIApplication and calls
    /// open(_:options:completionHandler:). Fallback for Tier 1.
    private func openURLViaResponderChain(_ url: URL) -> Bool {
        guard let applicationClass = NSClassFromString("UIApplication") else {
            return false
        }

        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: applicationClass) {
                let openSel = NSSelectorFromString("openURL:options:completionHandler:")
                if current.responds(to: openSel) {
                    let imp = current.method(for: openSel)
                    typealias OpenURLFunc = @convention(c) (NSObject, Selector, URL, NSDictionary, Any?) -> Void
                    let openURL = unsafeBitCast(imp, to: OpenURLFunc.self)
                    openURL(current, openSel, url, NSDictionary(), nil)
                    return true
                }
            }
            responder = current.next
        }

        NSLog("📎 Share Extension: could not find UIApplication in responder chain")
        return false
    }

    /// Posts a system-wide Darwin notification that the main app can observe
    /// when it is suspended or in background.
    private func postDarwinNotification() {
        let name = "com.bisonnotesai.shareExtensionDidSaveFile" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name), nil, nil, true
        )
    }

    // MARK: - Complete

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
