//
//  ShareViewController.swift
//  BisonNotes Share
//
//  iOS presentation and app-launch adapter for the shared Share Inbox
//  processor. The existing UIApplication fallbacks remain iOS-only.
//

import UIKit

final class ShareViewController: UIViewController {
    private let processor = ShareExtensionProcessor()
    private var hasStartedProcessing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !hasStartedProcessing else {
            return
        }
        hasStartedProcessing = true
        processSharedItems()
    }

    private func processSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem],
              !extensionItems.isEmpty else {
            NSLog("📎 Share Extension: no extension items found")
            completeRequest()
            return
        }

        processor.process(items: extensionItems) { [weak self] result in
            guard let self else {
                return
            }

            guard result.savedFileCount > 0, let importURL = result.importURL else {
                self.completeRequest()
                return
            }

            self.openMainApp(at: importURL) {
                self.completeRequest()
            }
        }
    }

    // MARK: - Open Main App

    /// Attempts to open the main app via its custom URL scheme so it imports
    /// shared files immediately. Runtime access remains isolated to the iOS
    /// extension; the native macOS extension uses NSExtensionContext.open.
    private func openMainApp(at url: URL, completion: @escaping () -> Void) {
        if openURLViaSharedApplication(url) {
            NSLog("📎 Share Extension: opened main app via UIApplication.shared")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion()
            }
            return
        }

        if openURLViaResponderChain(url) {
            NSLog("📎 Share Extension: opened main app via responder chain")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion()
            }
            return
        }

        ShareExtensionProcessor.postDarwinNotification()
        NSLog("📎 Share Extension: posted Darwin notification as fallback")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            completion()
        }
    }

    private func openURLViaSharedApplication(_ url: URL) -> Bool {
        guard let appClass = NSClassFromString("UIApplication") else {
            NSLog("📎 Share Extension: UIApplication class not found")
            return false
        }

        let sharedSelector = NSSelectorFromString("sharedApplication")
        guard let unmanaged = (appClass as AnyObject).perform(sharedSelector),
              let application = unmanaged.takeUnretainedValue() as? NSObject else {
            NSLog("📎 Share Extension: could not get UIApplication.shared")
            return false
        }

        let openSelector = NSSelectorFromString("openURL:options:completionHandler:")
        guard application.responds(to: openSelector) else {
            NSLog("📎 Share Extension: UIApplication does not support URL opening")
            return false
        }

        let implementation = application.method(for: openSelector)
        typealias OpenURLFunction = @convention(c) (
            NSObject,
            Selector,
            URL,
            NSDictionary,
            Any?
        ) -> Void
        let openURL = unsafeBitCast(implementation, to: OpenURLFunction.self)
        openURL(application, openSelector, url, NSDictionary(), nil)
        return true
    }

    private func openURLViaResponderChain(_ url: URL) -> Bool {
        guard let applicationClass = NSClassFromString("UIApplication") else {
            return false
        }

        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: applicationClass) {
                let openSelector = NSSelectorFromString("openURL:options:completionHandler:")
                if current.responds(to: openSelector) {
                    let implementation = current.method(for: openSelector)
                    typealias OpenURLFunction = @convention(c) (
                        NSObject,
                        Selector,
                        URL,
                        NSDictionary,
                        Any?
                    ) -> Void
                    let openURL = unsafeBitCast(implementation, to: OpenURLFunction.self)
                    openURL(current, openSelector, url, NSDictionary(), nil)
                    return true
                }
            }
            responder = current.next
        }

        NSLog("📎 Share Extension: could not find UIApplication in responder chain")
        return false
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
