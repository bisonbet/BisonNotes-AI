import XCTest
@testable import BisonNotes_AI

/// Retention for diagnostic exports. A 7.9 MB export was 96% MetricKit
/// payloads, pretty-printed and up to six weeks old, and its error log reached
/// back three months; these pin the rules that keep an export small and recent.
final class DiagnosticRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let day: TimeInterval = 24 * 3600

    // MARK: - Rolling log lines

    private func line(_ ageInDays: Double, _ text: String) -> String {
        let date = now.addingTimeInterval(-ageInDays * day)
        return "[\(ISO8601DateFormatter().string(from: date))] [INFO] [General] \(text)"
    }

    func testExpiredLinesAreDroppedAndRecentOnesKept() {
        let lines = [line(90, "august"), line(20, "october"), line(13, "recent"), line(0, "now")]
        let kept = LogTrimPolicy.dropExpired(lines: lines, now: now, maxAge: LogTrimPolicy.maximumLineAge)
        XCTAssertEqual(kept, [line(13, "recent"), line(0, "now")])
    }

    func testALineWithoutATimestampIsNeverAgedOut() {
        let lines = ["legacy line with no timestamp", line(0, "now")]
        XCTAssertEqual(LogTrimPolicy.dropExpired(lines: lines, now: now, maxAge: day), lines)
    }

    func testTimestampReadsTheFormatAppLogWrites() {
        XCTAssertEqual(
            LogTrimPolicy.timestamp(of: "[2026-11-08T01:56:00Z] [INFO] [General] x"),
            Date(timeIntervalSince1970: 1_794_102_960)
        )
        XCTAssertNil(LogTrimPolicy.timestamp(of: "no bracket"))
    }

    // MARK: - MetricKit

    private func timestamp(_ ageInDays: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: now.addingTimeInterval(-ageInDays * day))
    }

    private func payload(_ ageInDays: Double, kinds: [String], padding: Int = 0) -> [String: Any] {
        var payload: [String: Any] = [
            "timeStampBegin": timestamp(ageInDays),
            "timeStampEnd": timestamp(ageInDays)
        ]
        for kind in kinds {
            payload[kind] = [["version": "1.0.0", "padding": String(repeating: "x", count: padding)]]
        }
        return payload
    }

    private func entries(_ payloads: [[String: Any]]) -> [MetricKitDiagnosticStore.Entry] {
        payloads.flatMap { MetricKitDiagnosticStore.entries(splitting: $0, receivedAt: now) }
    }

    func testAPayloadSplitsIntoOneEntryPerDiagnosticKind() {
        let split = entries([payload(1, kinds: ["crashDiagnostics", "diskWriteExceptionDiagnostics"])])
        XCTAssertEqual(split.map(\.kind), ["crashDiagnostics", "diskWriteExceptionDiagnostics"])
        XCTAssertEqual(split.map(\.isPriority), [true, false])
        XCTAssertNil(split[0].payload["diskWriteExceptionDiagnostics"])
        XCTAssertNotNil(split[0].payload["timeStampEnd"])
    }

    func testEntriesOlderThanTheWindowAreDropped() {
        let kept = MetricKitDiagnosticStore.retain(
            entries([
                payload(44, kinds: ["crashDiagnostics"]),
                payload(15, kinds: ["diskWriteExceptionDiagnostics"]),
                payload(2, kinds: ["diskWriteExceptionDiagnostics"])
            ]),
            now: now
        )
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].kind, "diskWriteExceptionDiagnostics")
    }

    /// The regression: five disk-write reports had pushed out the only crash.
    func testResourceReportsCannotEvictACrash() {
        let crash = payload(10, kinds: ["crashDiagnostics"])
        let diskWrites = (0..<8).map { payload(Double(8 - $0), kinds: ["diskWriteExceptionDiagnostics"]) }
        let kept = MetricKitDiagnosticStore.retain(entries([crash] + diskWrites), now: now)

        XCTAssertEqual(kept.filter(\.isPriority).count, 1, "The crash survives")
        XCTAssertEqual(
            kept.filter { !$0.isPriority }.count,
            MetricKitDiagnosticStore.maximumOtherEntries
        )
        XCTAssertEqual(kept.map(\.date), kept.map(\.date).sorted(), "Kept oldest first")
    }

    func testOverTheByteBudgetResourceReportsGoFirst() {
        let large = MetricKitDiagnosticStore.maximumBytes / 2
        let kept = MetricKitDiagnosticStore.retain(
            entries([
                payload(3, kinds: ["hangDiagnostics"], padding: large),
                payload(2, kinds: ["diskWriteExceptionDiagnostics"], padding: large),
                payload(1, kinds: ["cpuExceptionDiagnostics"], padding: 10)
            ]),
            now: now
        )
        XCTAssertEqual(kept.map(\.kind), ["hangDiagnostics", "cpuExceptionDiagnostics"])
    }

    func testOneOversizedCrashIsStillKept() {
        let kept = MetricKitDiagnosticStore.retain(
            entries([payload(1, kinds: ["crashDiagnostics"], padding: MetricKitDiagnosticStore.maximumBytes * 2)]),
            now: now
        )
        XCTAssertEqual(kept.count, 1)
    }

    func testStoredFileIsCompactAndRoundTrips() throws {
        let original = entries([payload(1, kinds: ["crashDiagnostics", "hangDiagnostics"])])
        let data = try XCTUnwrap(MetricKitDiagnosticStore.encode(original))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"), "No pretty-printing")

        let decoded = MetricKitDiagnosticStore.decode(data, now: now)
        XCTAssertEqual(decoded.map(\.kind), original.map(\.kind))
        XCTAssertEqual(decoded.map(\.date), original.map(\.date))
    }

    func testLegacyArrayFilesAreReadAndRewritten() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrickit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = [payload(40, kinds: ["diskWriteExceptionDiagnostics"]), payload(1, kinds: ["crashDiagnostics"])]
        try JSONSerialization.data(withJSONObject: legacy, options: .prettyPrinted).write(to: url)

        let retained = MetricKitDiagnosticStore.loadRetained(at: url, now: now)

        XCTAssertEqual(retained.map(\.kind), ["crashDiagnostics"])
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(rewritten?["version"] as? Int, 2)
    }

    func testRecordAppendsAndPrunes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrickit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        MetricKitDiagnosticStore.record([payload(30, kinds: ["hangDiagnostics"])], at: url, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Nothing in the window: no file")

        MetricKitDiagnosticStore.record([payload(1, kinds: ["crashDiagnostics"])], at: url, now: now)
        MetricKitDiagnosticStore.record([payload(0, kinds: ["diskWriteExceptionDiagnostics"])], at: url, now: now)
        XCTAssertEqual(
            MetricKitDiagnosticStore.loadRetained(at: url, now: now).map(\.kind),
            ["crashDiagnostics", "diskWriteExceptionDiagnostics"]
        )
    }

    /// Delivery and export-time pruning run on different queues; concurrent
    /// read-modify-writes must not lose an entry.
    func testConcurrentRecordsAndPrunesLoseNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrickit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let payloads = (0..<MetricKitDiagnosticStore.maximumPriorityEntries).map {
            payload(Double($0) + 1, kinds: ["crashDiagnostics"])
        }
        let now = self.now

        DispatchQueue.concurrentPerform(iterations: payloads.count * 2) { index in
            if index % 2 == 0 {
                MetricKitDiagnosticStore.record([payloads[index / 2]], at: url, now: now)
            } else {
                _ = MetricKitDiagnosticStore.loadRetained(at: url, now: now)
            }
        }

        XCTAssertEqual(
            MetricKitDiagnosticStore.loadRetained(at: url, now: now).count,
            payloads.count
        )
    }

    func testExportPutsEachPayloadOnOneLine() {
        let text = MetricKitDiagnosticStore.exportText(entries([payload(1, kinds: ["crashDiagnostics"])]))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("] crashDiagnostics"))
        XCTAssertTrue(lines[1].hasPrefix("{"))

        XCTAssertTrue(MetricKitDiagnosticStore.exportText([]).hasPrefix("No MetricKit diagnostics"))
    }
}
