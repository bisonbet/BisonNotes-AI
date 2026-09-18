//
//  DiagnosticUploadQueue.swift
//  BisonNotes AI
//

import Foundation

struct DiagnosticUploadConfiguration: Sendable, Equatable {
    let endpoint: URL?

    /// Production is deliberately unconfigured until a reviewed receiver,
    /// retention policy, and privacy disclosure have been verified.
    static let productionDisabled = DiagnosticUploadConfiguration(endpoint: nil)

    init(endpoint: URL?) {
        self.endpoint = Self.isAllowed(endpoint) ? endpoint : nil
    }

    private static func isAllowed(_ endpoint: URL?) -> Bool {
        guard let endpoint, let scheme = endpoint.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = endpoint.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

struct DiagnosticHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private struct DiagnosticUploadAcknowledgement: Codable {
    let accepted: Bool
    let eventID: UUID
}

private enum DiagnosticUploadError: Error {
    case invalidEndpoint
    case invalidResponse
}

enum DiagnosticUploadOutcome: Sendable {
    case accepted
    case retry(after: TimeInterval?)
    case discard
}

private enum DiagnosticHTTPTransport {
    static func send(_ request: URLRequest) async throws -> DiagnosticHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30

        let delegate = DiagnosticRedirectRejectingDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (body, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiagnosticUploadError.invalidResponse
        }

        var headers = [String: String]()
        for (key, value) in httpResponse.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key.lowercased()] = value
        }
        return DiagnosticHTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }
}

private final class DiagnosticRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A diagnostic request must never follow an unapproved redirect.
        completionHandler(nil)
    }
}

actor DiagnosticUploader {
    typealias Transport = @Sendable (URLRequest) async throws -> DiagnosticHTTPResponse

    private let endpoint: URL
    private let transport: Transport

    init(
        endpoint: URL,
        transport: @escaping Transport = { request in
            try await DiagnosticHTTPTransport.send(request)
        }
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func upload(_ envelope: CrashEnvelope) async -> DiagnosticUploadOutcome {
        guard DiagnosticUploadConfiguration(endpoint: endpoint).endpoint != nil else {
            return .discard
        }
        guard let body = try? DiagnosticPolicy.jsonEncoder().encode(envelope),
              body.count <= DiagnosticPolicy.maximumEnvelopeBytes else {
            return .discard
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(envelope.idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")

        do {
            let response = try await transport(request)
            switch response.statusCode {
            case 200...299:
                guard let acknowledgement = try? DiagnosticPolicy.jsonDecoder().decode(
                    DiagnosticUploadAcknowledgement.self,
                    from: response.body
                ),
                acknowledgement.accepted,
                acknowledgement.eventID == envelope.idempotencyKey else {
                    return .discard
                }
                return .accepted

            case 408, 429, 500...599:
                return .retry(after: retryAfter(from: response.headers))

            default:
                // Permanent validation/authentication/policy failures are
                // discarded inside the same bounded queue; request bodies are
                // never copied into logs or a dead-letter store.
                return .discard
            }
        } catch {
            return .retry(after: nil)
        }
    }

    private func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let value = headers.first(where: {
            $0.key.caseInsensitiveCompare("retry-after") == .orderedSame
        })?.value else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

actor DiagnosticUploadQueue {
    struct Entry: Codable, Sendable, Equatable {
        let envelope: CrashEnvelope
        let enqueuedAt: Date
        var retryCount: Int
        var nextAttemptAt: Date
    }

    private struct StoredQueue: Codable {
        let entries: [Entry]
    }

    private let fileURL: URL
    private let uploader: DiagnosticUploader?
    private let now: @Sendable () -> Date
    private let jitterProvider: @Sendable () -> Double
    private var entries: [Entry]

    init(
        fileURL: URL = DiagnosticUploadQueue.defaultFileURL(),
        uploader: DiagnosticUploader?,
        now: @escaping @Sendable () -> Date = { Date() },
        jitterProvider: @escaping @Sendable () -> Double = { Double.random(in: 0...5) }
    ) {
        self.fileURL = fileURL
        self.uploader = uploader
        self.now = now
        self.jitterProvider = jitterProvider
        self.entries = Self.load(from: fileURL)
    }

    @discardableResult
    func enqueue(_ envelope: CrashEnvelope) -> Bool {
        guard uploader != nil else {
            return false
        }
        guard envelope.encodedSize ?? (DiagnosticPolicy.maximumEnvelopeBytes + 1)
                <= DiagnosticPolicy.maximumEnvelopeBytes else {
            return false
        }

        purgeExpired(now: now())
        guard !entries.contains(where: { $0.envelope.idempotencyKey == envelope.idempotencyKey }) else {
            return false
        }

        let timestamp = now()
        entries.append(Entry(
            envelope: envelope,
            enqueuedAt: timestamp,
            retryCount: 0,
            nextAttemptAt: timestamp
        ))
        trimToPolicy()
        persist()
        return entries.contains(where: { $0.envelope.idempotencyKey == envelope.idempotencyKey })
    }

    func process(consent: DiagnosticConsentSnapshot) async {
        guard consent.isEnabled, let epoch = consent.epoch else {
            clear()
            return
        }

        let currentDate = now()
        entries.removeAll { entry in
            entry.enqueuedAt < currentDate.addingTimeInterval(-DiagnosticPolicy.queueRetention)
                || entry.envelope.consentEpoch != epoch
        }
        guard let uploader else {
            clear()
            return
        }

        for entry in entries where entry.nextAttemptAt <= currentDate {
            let outcome = await uploader.upload(entry.envelope)
            guard let index = entries.firstIndex(where: {
                $0.envelope.idempotencyKey == entry.envelope.idempotencyKey
            }) else {
                continue
            }

            switch outcome {
            case .accepted, .discard:
                entries.remove(at: index)
                persist()

            case .retry(let requestedDelay):
                var updated = entries[index]
                updated.retryCount += 1
                updated.nextAttemptAt = currentDate.addingTimeInterval(
                    retryDelay(requestedDelay: requestedDelay, retryCount: updated.retryCount)
                )
                entries[index] = updated
                persist()
            }
        }
    }

    func pendingEntries() -> [Entry] {
        entries
    }

    func count() -> Int {
        entries.count
    }

    func encodedByteCount() -> Int {
        encodedData()?.count ?? 0
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func retryDelay(requestedDelay: TimeInterval?, retryCount: Int) -> TimeInterval {
        if let requestedDelay, requestedDelay.isFinite, requestedDelay >= 0 {
            // Persist long Retry-After values instead of sleeping in a launch
            // or foreground task. The queue will be eligible on a later pass.
            return min(requestedDelay, 24 * 60 * 60)
        }

        let exponent = min(max(retryCount - 1, 0), 10)
        let exponential = min(pow(2.0, Double(exponent)) * 5, 6 * 60 * 60)
        return exponential + max(0, min(jitterProvider(), 30))
    }

    private func purgeExpired(now: Date) {
        entries.removeAll {
            $0.enqueuedAt < now.addingTimeInterval(-DiagnosticPolicy.queueRetention)
        }
    }

    private func trimToPolicy() {
        while entries.count > DiagnosticPolicy.maximumQueuedEnvelopes
                || (encodedData()?.count ?? 0) > DiagnosticPolicy.maximumQueueBytes {
            guard !entries.isEmpty else { break }
            entries.removeFirst()
        }
    }

    private func persist() {
        guard let data = encodedData() else { return }
        DiagnosticStorageSupport.prepareDirectory(for: fileURL)
        do {
            try data.write(to: fileURL, options: .atomic)
            DiagnosticStorageSupport.protectAndExcludeFromBackup(fileURL)
        } catch {
            // Automatic diagnostics are never allowed to make a storage error
            // visible to the user-facing recording or recovery path.
        }
    }

    private func encodedData() -> Data? {
        try? DiagnosticPolicy.jsonEncoder().encode(StoredQueue(entries: entries))
    }

    private static func load(from fileURL: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(StoredQueue.self, from: data))?.entries ?? []
    }

    private static func defaultFileURL() -> URL {
        let directory = DiagnosticStorageSupport.defaultDirectory()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                DiagnosticStorageSupport.directoryName,
                isDirectory: true
            )
        return directory.appendingPathComponent(DiagnosticStorageSupport.queueFileName)
    }
}
