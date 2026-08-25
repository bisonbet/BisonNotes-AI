//
//  ShareViewController.swift
//  BisonNotes Share macOS
//

import AppKit

final class ShareViewController: NSViewController {
    private let processor = ShareExtensionProcessor()
    private var hasStartedProcessing = false

    override func loadView() {
        view = NSView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard !hasStartedProcessing else {
            return
        }
        hasStartedProcessing = true
        processSharedItems()
    }

    private func processSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem],
              !extensionItems.isEmpty else {
            NSLog("📎 Mac Share Extension: no extension items found")
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

            self.openMainApp(at: importURL)
        }
    }

    private func openMainApp(at url: URL) {
        extensionContext?.open(url) { [weak self] opened in
            if opened {
                NSLog("📎 Mac Share Extension: requested host app activation")
            } else {
                ShareExtensionProcessor.postDarwinNotification()
                NSLog("📎 Mac Share Extension: notified running host app")
            }

			Task { @MainActor [weak self] in
				self?.completeRequest()
			}
        }
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
