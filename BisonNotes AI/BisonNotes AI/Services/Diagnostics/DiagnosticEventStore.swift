//
//  DiagnosticEventStore.swift
//  BisonNotes AI
//

import Foundation

actor DiagnosticEventStore {
    private struct StoredEvents: Codable {
        let events: [DiagnosticEvent]
    }

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var events: [DiagnosticEvent]

    init(
        fileURL: URL = DiagnosticEventStore.defaultFileURL(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.events = Self.load(from: fileURL)
    }

    func append(_ event: DiagnosticEvent) {
        let cutoff = now().addingTimeInterval(-DiagnosticPolicy.eventRetention)
        events.removeAll { $0.occurredAt < cutoff }
        guard !events.contains(where: { $0.eventID == event.eventID }) else {
            return
        }
        events.append(event)
        trimToPolicy()
        persist()
    }

    func events(
        overlapping interval: DateInterval,
        applicationVersion: String,
        applicationBuild: String
    ) -> [DiagnosticEvent] {
        let cutoff = now().addingTimeInterval(-DiagnosticPolicy.eventRetention)
        events.removeAll { $0.occurredAt < cutoff }
        return events.filter { event in
            event.report == nil
                && event.applicationVersion == applicationVersion
                && event.applicationBuild == applicationBuild
                && interval.contains(event.occurredAt)
        }
    }

    func allEvents() -> [DiagnosticEvent] {
        let cutoff = now().addingTimeInterval(-DiagnosticPolicy.eventRetention)
        events.removeAll { $0.occurredAt < cutoff }
        return events
    }

    func count() -> Int {
        events.count
    }

    func containsEventID(_ eventID: UUID) -> Bool {
        events.contains { $0.eventID == eventID }
    }

    func encodedByteCount() -> Int {
        encodedData()?.count ?? 0
    }

    func clear() {
        events.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func trimToPolicy() {
        while events.count > DiagnosticPolicy.maximumStructuredEvents
                || (encodedData()?.count ?? 0) > DiagnosticPolicy.maximumEventStoreBytes {
            guard !events.isEmpty else { break }
            events.removeFirst()
        }
    }

    private func persist() {
        guard let data = encodedData() else { return }
        DiagnosticStorageSupport.prepareDirectory(for: fileURL)
        do {
            try data.write(to: fileURL, options: .atomic)
            DiagnosticStorageSupport.protectAndExcludeFromBackup(fileURL)
        } catch {
            // Telemetry persistence is best effort. Never surface storage
            // failures to recording, startup, or recovery callers.
        }
    }

    private func encodedData() -> Data? {
        try? DiagnosticPolicy.jsonEncoder().encode(StoredEvents(events: events))
    }

    private static func load(from fileURL: URL) -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? DiagnosticPolicy.jsonDecoder().decode(StoredEvents.self, from: data) else {
            return []
        }
        return stored.events
    }

    private static func defaultFileURL() -> URL {
        let directory = DiagnosticStorageSupport.defaultDirectory()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                DiagnosticStorageSupport.directoryName,
                isDirectory: true
            )
        return directory.appendingPathComponent(DiagnosticStorageSupport.eventStoreFileName)
    }
}
