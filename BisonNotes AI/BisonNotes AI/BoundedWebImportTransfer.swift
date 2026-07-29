import Foundation

struct WebImportTransferResult {
    let response: HTTPURLResponse
    let route: WebImportRoute
}

final class BoundedWebImportTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let stagingURL: URL
    private let routeResolver: (HTTPURLResponse) throws -> WebImportRoute
    private let sizeLimit: (WebImportRoute) -> Int64
    private let lock = NSLock()

    private var continuation: CheckedContinuation<WebImportTransferResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var response: HTTPURLResponse?
    private var route: WebImportRoute?
    private var activeSizeLimit: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var isComplete = false

    init(
        configuration: URLSessionConfiguration,
        stagingURL: URL,
        routeResolver: @escaping (HTTPURLResponse) throws -> WebImportRoute,
        sizeLimit: @escaping (WebImportRoute) -> Int64
    ) {
        self.configuration = configuration
        self.stagingURL = stagingURL
        self.routeResolver = routeResolver
        self.sizeLimit = sizeLimit
    }

    func start(request: URLRequest) async throws -> WebImportTransferResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !isComplete else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let delegateQueue = OperationQueue()
                delegateQueue.maxConcurrentOperationCount = 1
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebImportError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw WebImportError.httpStatus(httpResponse.statusCode)
            }

            let route = try routeResolver(httpResponse)
            let limit = sizeLimit(route)
            if httpResponse.expectedContentLength > limit {
                throw WebImportError.fileTooLarge(httpResponse.expectedContentLength, limit)
            }

            let handle = try FileHandle(forWritingTo: stagingURL)
            lock.lock()
            guard !isComplete else {
                lock.unlock()
                try? handle.close()
                completionHandler(.cancel)
                return
            }
            self.response = httpResponse
            self.route = route
            activeSizeLimit = limit
            fileHandle = handle
            lock.unlock()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !isComplete, let fileHandle else {
            lock.unlock()
            return
        }

        let dataSize = Int64(data.count)
        let (newTotal, overflow) = receivedBytes.addingReportingOverflow(dataSize)
        guard !overflow, newTotal <= activeSizeLimit else {
            let attemptedSize = overflow ? Int64.max : newTotal
            let limit = activeSizeLimit
            lock.unlock()
            dataTask.cancel()
            finish(.failure(WebImportError.fileTooLarge(attemptedSize, limit)))
            return
        }

        do {
            try fileHandle.write(contentsOf: data)
            receivedBytes = newTotal
            lock.unlock()
        } catch {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url,
              WebImportDownloader.isAllowedDownloadURL(redirectURL) else {
            completionHandler(nil)
            finish(.failure(WebImportError.insecureURL))
            return
        }

        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        lock.lock()
        let result = response.flatMap { response in
            route.map { WebImportTransferResult(response: response, route: $0) }
        }
        lock.unlock()

        if let result {
            finish(.success(result))
        } else {
            finish(.failure(WebImportError.invalidResponse))
        }
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<WebImportTransferResult, Error>) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }

        isComplete = true
        let continuation = self.continuation
        self.continuation = nil
        let fileHandle = self.fileHandle
        self.fileHandle = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        try? fileHandle?.close()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
