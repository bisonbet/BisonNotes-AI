//
//  DiagnosticRetention.swift
//  BisonNotes AI
//
//  Retention rules for everything a diagnostic export carries: the rolling
//  breadcrumb and error logs, and the MetricKit payloads iOS delivers.
//
//  Foundation-only on purpose, so the rules are covered by the Linux swift-check
//  tests as well as by Xcode.
//

import Foundation

// MARK: - Rolling Log Lines

/// Budget rules for the rolling files that survive a crash.
///
/// A line-count cap alone does not bound a log file. A single message can be a
/// model response, a decoded payload, or a CloudKit error description, and one
/// 350 KB line was enough to push a 500-line error log past 4 MB — which then
/// cost a 4 MB read and a 4 MB rewrite on *every* subsequent log call. So each
/// line is clamped first and the file carries a byte ceiling as well.
///
/// Nor does either cap bound the *age* of what is kept: a quiet error log stayed
/// under both and still carried three months of history into every export. Lines
/// older than the retention window are dropped too.
///
/// Pure so the budgets can be tested without touching the filesystem.
enum LogTrimPolicy {
    /// How long a persisted breadcrumb or error line stays in the rolling files.
    static let maximumLineAge: TimeInterval = 14 * 24 * 3600

    /// Clamps one line so a single huge message cannot consume the whole budget.
    /// Keeps the head, which is where the message and the first frames live.
    static func clamp(_ line: String, maxBytes: Int) -> String {
        let flattened = line.replacingOccurrences(of: "\n", with: "⏎")
        guard flattened.utf8.count > maxBytes else { return flattened }

        let marker = "…[truncated]"
        let budget = max(0, maxBytes - marker.utf8.count)
        var kept = String()
        var used = 0
        for character in flattened {
            let width = String(character).utf8.count
            if used + width > budget { break }
            kept.append(character)
            used += width
        }
        return kept + marker
    }

    /// Drops the oldest lines until the joined text fits both budgets.
    /// Always keeps at least the newest line, so a log call is never a no-op.
    static func trim(lines: [String], maxLines: Int, maxBytes: Int) -> [String] {
        var kept = lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
        var total = kept.reduce(0) { $0 + $1.utf8.count + 1 }
        var firstKept = 0
        while total > maxBytes, firstKept < kept.count - 1 {
            total -= kept[firstKept].utf8.count + 1
            firstKept += 1
        }
        if firstKept > 0 { kept = Array(kept.dropFirst(firstKept)) }
        return kept
    }

    /// Drops lines whose leading `[ISO-8601]` timestamp is older than `maxAge`.
    ///
    /// A line without a readable timestamp is kept: every persisted line is
    /// written with one, so an unreadable one is a format this rule does not
    /// understand, and guessing its age could discard the only record of a crash.
    /// Lines are appended in time order, so the scan stops at the first line that
    /// is recent enough rather than parsing the whole file.
    static func dropExpired(lines: [String], now: Date, maxAge: TimeInterval) -> [String] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let firstRecent = lines.firstIndex { line in
            guard let date = timestamp(of: line) else { return true }
            return date >= cutoff
        } ?? lines.endIndex
        return Array(lines[firstRecent...])
    }

    /// The timestamp `AppLog` writes at the start of every persisted line.
    static func timestamp(of line: String) -> Date? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let text = String(line[line.index(after: line.startIndex)..<close])
        return try? Date(text, strategy: .iso8601)
    }
}

// MARK: - MetricKit Payloads

/// Stores the MetricKit diagnostics iOS delivers, within an age, count and byte budget.
///
/// The previous store kept the last five payloads of any kind, pretty-printed,
/// with no age or size limit. The payloads are deeply nested call-stack trees,
/// so indentation alone made them about 11x larger: five disk-write reports
/// were 7.6 MB of a 7.9 MB export, the oldest six weeks old, and between them
/// they had already pushed out the only crash report.
///
/// So each payload is split into one entry per diagnostic kind, crashes and
/// hangs are kept apart from the far more frequent disk-write and CPU reports
/// so those can never evict them, everything is stored and exported as compact
/// JSON, and entries age out after ``maximumAge``.
enum MetricKitDiagnosticStore {
    struct Entry {
        /// When the diagnostic happened: the payload's `timeStampEnd`, or the
        /// receipt time when that is missing or unreadable.
        let date: Date
        /// The payload key this entry came from, e.g. `crashDiagnostics`.
        let kind: String
        /// `timeStampBegin`, `timeStampEnd` and this kind's diagnostics array.
        let payload: [String: Any]

        var isPriority: Bool { MetricKitDiagnosticStore.priorityKinds.contains(kind) }
    }

    static let maximumAge: TimeInterval = 14 * 24 * 3600
    static let maximumPriorityEntries = 5
    static let maximumOtherEntries = 3
    /// The whole file, compact. The newest crash or hang is kept even above it.
    static let maximumBytes = 1_000_000

    /// Kinds that explain a lost session. Everything else is a resource report.
    static let priorityKinds: Set<String> = ["crashDiagnostics", "hangDiagnostics"]

    static let fileName = "metrickit_diagnostics.json"

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    // MARK: File

    /// Adds newly delivered payloads (each a `jsonRepresentation()` object) to
    /// the store at `url`, then applies the retention budget.
    static func record(_ payloads: [[String: Any]], at url: URL, now: Date = Date()) {
        var entries = load(at: url, now: now)
        for payload in payloads {
            entries += self.entries(splitting: payload, receivedAt: now)
        }
        write(retain(entries, now: now), to: url)
    }

    /// The retained entries at `url`. Rewrites the file when retention dropped
    /// anything, so expired payloads leave the device even when no new one arrives.
    static func loadRetained(at url: URL, now: Date = Date()) -> [Entry] {
        let stored = load(at: url, now: now)
        let retained = retain(stored, now: now)
        if retained.count != stored.count || isLegacyFile(at: url) {
            write(retained, to: url)
        }
        return retained
    }

    private static func load(at url: URL, now: Date) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data, now: now)
    }

    private static func write(_ entries: [Entry], to url: URL) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func isLegacyFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [Any]
    }

    // MARK: Pure rules

    /// One entry per diagnostic kind in a payload.
    static func entries(splitting payload: [String: Any], receivedAt: Date) -> [Entry] {
        let date = (payload["timeStampEnd"] as? String).flatMap(parseTimestamp) ?? receivedAt
        return payload.keys.sorted().compactMap { key -> Entry? in
            guard key.hasSuffix("Diagnostics"),
                  let diagnostics = payload[key] as? [Any],
                  !diagnostics.isEmpty else { return nil }
            var single: [String: Any] = [key: diagnostics]
            single["timeStampBegin"] = payload["timeStampBegin"]
            single["timeStampEnd"] = payload["timeStampEnd"]
            return Entry(date: date, kind: key, payload: single)
        }
    }

    /// Applies the age, per-class count and byte budgets.
    ///
    /// Over the byte budget, resource reports go first, oldest first; then the
    /// oldest crashes and hangs. The newest entry is always kept, so one oversized
    /// crash report is still exported rather than silently discarded.
    static func retain(_ entries: [Entry], now: Date) -> [Entry] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        let recent = entries.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        var kept = Array(recent.filter(\.isPriority).suffix(maximumPriorityEntries))
            + Array(recent.filter { !$0.isPriority }.suffix(maximumOtherEntries))
        kept.sort { $0.date < $1.date }

        var total = kept.reduce(0) { $0 + byteCount(of: $1) }
        while total > maximumBytes, kept.count > 1 {
            // Sorted oldest first, so index 0 is the oldest crash or hang and,
            // with more than one entry left, never the newest.
            let victim = kept.firstIndex { !$0.isPriority } ?? 0
            total -= byteCount(of: kept[victim])
            kept.remove(at: victim)
        }
        return kept
    }

    /// Reads the current `{version: 2, entries: [...]}` format, or the legacy
    /// top-level array of whole payloads written by earlier builds.
    static func decode(_ data: Data, now: Date) -> [Entry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let legacy = object as? [[String: Any]] {
            return legacy.flatMap { entries(splitting: $0, receivedAt: now) }
        }
        guard let root = object as? [String: Any],
              let stored = root["entries"] as? [[String: Any]] else { return [] }
        return stored.compactMap { item in
            guard let seconds = item["date"] as? Double,
                  let kind = item["kind"] as? String,
                  let payload = item["payload"] as? [String: Any] else { return nil }
            return Entry(date: Date(timeIntervalSince1970: seconds), kind: kind, payload: payload)
        }
    }

    /// Compact JSON: indentation was most of the old file's size.
    static func encode(_ entries: [Entry]) -> Data? {
        let stored: [[String: Any]] = entries.map {
            ["date": $0.date.timeIntervalSince1970, "kind": $0.kind, "payload": $0.payload]
        }
        let root: [String: Any] = ["version": 2, "entries": stored]
        guard JSONSerialization.isValidJSONObject(root) else { return nil }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Export text: a readable header per entry, then its payload as one line of
    /// compact JSON, which tools can still pretty-print when it is needed.
    static func exportText(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else {
            return "No MetricKit diagnostics from the last \(Int(maximumAge / 86400)) days. "
                + "iOS may deliver crash and hang payloads on a later launch."
        }
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            let json = (try? JSONSerialization.data(withJSONObject: entry.payload, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "[\(formatter.string(from: entry.date))] \(entry.kind)\n\(json)"
        }.joined(separator: "\n")
    }

    static func byteCount(of entry: Entry) -> Int {
        (try? JSONSerialization.data(withJSONObject: entry.payload).count) ?? 0
    }

    /// MetricKit writes `yyyy-MM-dd HH:mm:ss` with no zone; it is device-local.
    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
