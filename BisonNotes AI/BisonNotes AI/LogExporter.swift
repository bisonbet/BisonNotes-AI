//
//  LogExporter.swift
//  BisonNotes AI
//
//  Fetches the app's OSLog entries, persistent error buffer, and MetricKit crash
//  diagnostics, then exports them to a shareable text file.
//

import Foundation
import OSLog
import UIKit
import SwiftUI
import MessageUI

// MARK: - Log Exporter

struct LogExporter {

    static let supportEmail = "support@bisonnetworking.com"

    /// Builds a comprehensive diagnostic file containing:
    /// 1. Current session OSLog entries
    /// 2. Persistent error buffer (survives crashes)
    /// 3. MetricKit crash/hang diagnostics (if any)
    static func exportLogs() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        var sections = [String]()

        // ── Header ──
        let device = UIDevice.current
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let previousCrash = AppLog.shared.previousSessionCrashed

        let header = """
        BisonNotes AI Diagnostic Log
        App Version: \(appVersion) (\(buildNumber))
        Device: \(device.model), iOS \(device.systemVersion)
        Exported: \(formatter.string(from: Date()))
        Previous session crashed: \(previousCrash ? "YES" : "No")
        """
        sections.append(header)

        // ── Section 1: Current Session Logs (OSLogStore) ──
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let cutoff = store.position(date: Date().addingTimeInterval(-24 * 3600))
            let subsystem = Bundle.main.bundleIdentifier ?? "com.bisonnotes.app"
            let entries = try store.getEntries(at: cutoff)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == subsystem }

            var logLines = [String]()
            logLines.append("")
            logLines.append(sectionHeader("CURRENT SESSION LOGS (\(entries.count) entries)"))
            for entry in entries {
                let level = levelString(entry.level)
                logLines.append("[\(formatter.string(from: entry.date))] [\(level)] [\(entry.category)] \(entry.composedMessage)")
            }
            sections.append(logLines.joined(separator: "\n"))
        } catch {
            sections.append("\n" + sectionHeader("CURRENT SESSION LOGS") + "\nFailed to fetch: \(error.localizedDescription)")
        }

        // ── Section 2: Persistent Error Buffer (survives crashes) ──
        let errorLog = AppLog.shared.persistedErrorLog()
        if !errorLog.isEmpty {
            let errorLines = errorLog.components(separatedBy: "\n").filter { !$0.isEmpty }
            sections.append("\n" + sectionHeader("PERSISTENT ERROR LOG (\(errorLines.count) entries, survives crashes)") + "\n" + errorLog)
        }

        // ── Section 3: MetricKit Crash/Hang Diagnostics ──
        let metricKitURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("metrickit_diagnostics.json")
        if let data = try? Data(contentsOf: metricKitURL),
           let json = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            sections.append("\n" + sectionHeader("METRICKIT CRASH/HANG DIAGNOSTICS") + "\n" + prettyString)
        }

        // ── Write to file ──
        let text = sections.joined(separator: "\n")

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let timestamp = isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let fileName = "BisonNotes-Logs-\(timestamp).txt"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func sectionHeader(_ title: String) -> String {
        let bar = String(repeating: "─", count: 80)
        return "\(bar)\n \(title)\n\(bar)"
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:    return "DEBUG"
        case .info:     return "INFO"
        case .notice:   return "NOTICE"
        case .error:    return "ERROR"
        case .fault:    return "FAULT"
        default:        return "OTHER"
        }
    }
}

// MARK: - Log Email Presenter

/// Presents MFMailComposeViewController directly from the UIKit window,
/// bypassing SwiftUI's sheet stack to avoid "only a single sheet" conflicts.
/// Falls back to UIActivityViewController if Mail is not configured.
class LogEmailPresenter: NSObject, MFMailComposeViewControllerDelegate {

    static let shared = LogEmailPresenter()

    private var onDismiss: (() -> Void)?

    func presentLogEmail(logFileURL: URL, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss

        guard let rootVC = Self.topViewController() else {
            onDismiss()
            return
        }

        if MFMailComposeViewController.canSendMail() {
            let mail = MFMailComposeViewController()
            mail.mailComposeDelegate = self
            mail.setToRecipients([LogExporter.supportEmail])

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            mail.setSubject("BisonNotes AI Diagnostic Report - v\(appVersion)")
            mail.setMessageBody(
                "Hi,\n\nAttached is a diagnostic log from BisonNotes AI.\n\nPlease describe what happened (optional):\n\n",
                isHTML: false
            )

            if let data = try? Data(contentsOf: logFileURL) {
                mail.addAttachmentData(data, mimeType: "text/plain", fileName: logFileURL.lastPathComponent)
            }

            rootVC.present(mail, animated: true)
        } else {
            // Mail not configured — fall back to share sheet
            let activityVC = UIActivityViewController(activityItems: [logFileURL], applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, _, _, _ in
                onDismiss()
            }
            rootVC.present(activityVC, animated: true)
        }
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true) {
            self.onDismiss?()
            self.onDismiss = nil
        }
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var vc = root
        while let presented = vc.presentedViewController {
            vc = presented
        }
        return vc
    }
}
