//
//  WyomingWebSocketClient.swift
//  Audio Journal
//
//  WebSocket client for Wyoming protocol communication
//

import Foundation
import Network

@MainActor
class WyomingWebSocketClient: ObservableObject {

    // MARK: - Properties

    @Published var isConnected = false
    @Published var connectionError: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let serverURL: URL
    private var messageHandlers: [WyomingMessageType: (WyomingMessage) -> Void] = [:]
    /// Kept outside actor isolation so the nonisolated deinit can fail a
    /// still-pending connect instead of leaving its task suspended forever.
    private let connectionContinuation = WyomingConnectionContinuation()
    private var connectionCancellationRequested = false

    // MARK: - Initialization

    init(serverURL: URL) {
        self.serverURL = serverURL
        setupURLSession()
    }

    deinit {
        // Cancel WebSocket task synchronously
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        // A connect suspended at deallocation would otherwise never resume.
        connectionContinuation.finish(.failure(WyomingError.connectionFailed))
    }

    // MARK: - Connection Management

    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0  // Shorter timeout for connection test
        config.timeoutIntervalForResource = 60.0
        config.waitsForConnectivity = false  // Don't wait if no connectivity
        urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }

    func connect() async throws {
        guard !isConnected else { return }

        connectionCancellationRequested = false

        AppLog.shared.transcription("Connecting to Wyoming WebSocket server: \(serverURL)", level: .debug)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !connectionCancellationRequested else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                connectionContinuation.store(continuation)

                guard let session = urlSession else {
                    AppLog.shared.transcription("No URL session available", level: .error)
                    finishConnection(.failure(WyomingError.connectionFailed))
                    return
                }

                // Create WebSocket connection
                webSocketTask = session.webSocketTask(with: serverURL)
                webSocketTask?.resume()

                // Start listening for messages
                startListening()

                // Give the WebSocket time to connect
                Task { @MainActor [weak self] in
                    do {
                        // Wait for connection to establish
                        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

                        guard let self,
                              let task = self.webSocketTask,
                              task.state == .running else {
                            throw WyomingError.connectionFailed
                        }

                        AppLog.shared.transcription("Testing if WebSocket connection is established", level: .debug)
                        AppLog.shared.transcription("WebSocket task is running", level: .debug)
                        self.isConnected = true
                        self.connectionError = nil
                        AppLog.shared.transcription("WebSocket connection established")
                        self.finishConnection(.success(()))

                        // Send describe without making connection establishment
                        // depend on the server's response.
                        Task { @MainActor [weak self] in
                            do {
                                AppLog.shared.transcription("Sending describe message", level: .debug)
                                try await self?.sendMessage(WyomingMessageFactory.createDescribeMessage())
                                AppLog.shared.transcription("Describe message sent successfully", level: .debug)
                            } catch {
                                AppLog.shared.transcription("Failed to send describe message: \(error)", level: .error)
                            }
                        }
                    } catch {
                        AppLog.shared.transcription("Wyoming WebSocket connection failed: \(error)", level: .error)
                        self?.handleConnectionError(error)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingConnection()
            }
        }
    }

    private func cancelPendingConnection() {
        connectionCancellationRequested = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        finishConnection(.failure(CancellationError()))
    }

    private func finishConnection(_ result: Result<Void, Error>) {
        connectionContinuation.finish(result)
    }

    func disconnect() {
        AppLog.shared.transcription("Disconnecting from Wyoming WebSocket server", level: .debug)

        connectionCancellationRequested = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        finishConnection(.failure(WyomingError.connectionFailed))
        isConnected = false
        connectionError = nil
    }

    // MARK: - Message Handling

    private func startListening() {
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                Task { @MainActor in
                    await self?.handleWebSocketMessage(message)
                    self?.receiveNextMessage() // Continue listening
                }

            case .failure(let error):
                Task { @MainActor in
                    AppLog.shared.transcription("Wyoming WebSocket receive error: \(error)", level: .error)
                    self?.handleConnectionError(error)
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let text):
            await handleTextMessage(text)

        case .data(let data):
            // Wyoming protocol uses text messages, but we might receive binary audio data
            AppLog.shared.transcription("Received binary data: \(data.count) bytes", level: .debug)

        @unknown default:
            AppLog.shared.transcription("Unknown WebSocket message type", level: .error)
        }
    }

    private func handleTextMessage(_ text: String) async {
        AppLog.shared.transcription("Raw message received: \(text.prefix(200))", level: .debug)
        do {
            let wyomingMessage = try WyomingMessage.fromJSONString(text)
            AppLog.shared.transcription("Parsed Wyoming message: \(wyomingMessage.type)", level: .debug)

            // Call registered handler for this message type
            if let handler = messageHandlers[wyomingMessage.type] {
                AppLog.shared.transcription("Calling handler for message type: \(wyomingMessage.type)", level: .debug)
                handler(wyomingMessage)
            } else {
                AppLog.shared.transcription("No handler registered for message type: \(wyomingMessage.type)", level: .debug)
            }

        } catch {
            AppLog.shared.transcription("Failed to parse Wyoming message: \(error)", level: .error)
        }
    }

    private func handleConnectionError(_ error: Error) {
        isConnected = false
        connectionError = error.localizedDescription

        // If we have a pending connection continuation, fail it (but only once).
        finishConnection(.failure(error))
    }

    // MARK: - Message Sending

    func sendMessage(_ message: WyomingMessage) async throws {
        guard let webSocketTask = webSocketTask else {
            AppLog.shared.transcription("No WebSocket task available", level: .error)
            throw WyomingError.connectionFailed
        }

        // Don't require isConnected flag for the initial describe message
        if !isConnected && message.type != .describe {
            AppLog.shared.transcription("Not connected to Wyoming server", level: .error)
            throw WyomingError.connectionFailed
        }

        do {
            let jsonString = try message.toJSONString()
            AppLog.shared.transcription("Sending Wyoming message: \(message.type)", level: .debug)

            return try await withCheckedThrowingContinuation { continuation in
                webSocketTask.send(.string(jsonString)) { error in
                    if let error = error {
                        AppLog.shared.transcription("Failed to send Wyoming message: \(error)", level: .error)
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }

        } catch {
            AppLog.shared.transcription("Failed to encode Wyoming message: \(error)", level: .error)
            throw WyomingError.encodingFailed
        }
    }

    func sendAudioData(_ audioData: Data) async throws {
        guard isConnected, let webSocketTask = webSocketTask else {
            throw WyomingError.connectionFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            webSocketTask.send(.data(audioData)) { error in
                if let error = error {
                    AppLog.shared.transcription("Failed to send audio data: \(error)", level: .error)
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Message Handler Registration

    func registerHandler(for messageType: WyomingMessageType, handler: @escaping (WyomingMessage) -> Void) {
        messageHandlers[messageType] = handler
    }

    func removeHandler(for messageType: WyomingMessageType) {
        messageHandlers.removeValue(forKey: messageType)
    }

    // MARK: - Convenience Methods

    func sendDescribe() async throws {
        try await sendMessage(WyomingMessageFactory.createDescribeMessage())
    }

    /// Send a transcription request over WebSocket.
    ///
    /// - Parameters:
    ///   - language: Optional BCP-47 language code. When `nil` (the default),
    ///               the Wyoming server will auto-detect the spoken language.
    ///   - model: Optional ASR model identifier.
    func sendTranscribe(language: String? = nil, model: String? = nil) async throws {
        try await sendMessage(WyomingMessageFactory.createTranscribeMessage(language: language, model: model))
    }

    func sendAudioStart() async throws {
        try await sendMessage(WyomingMessageFactory.createAudioStartMessage())
    }

    func sendAudioStop() async throws {
        try await sendMessage(WyomingMessageFactory.createAudioStopMessage())
    }

    // MARK: - Connection Testing

    func testConnection() async -> Bool {
        do {
            try await connect()
            return isConnected
        } catch {
            AppLog.shared.transcription("Wyoming WebSocket connection test failed: \(error)", level: .error)
            return false
        }
    }
}

// MARK: - Connection State

extension WyomingWebSocketClient {

    var connectionStatus: String {
        if isConnected {
            return "Connected to Wyoming server"
        } else if let error = connectionError {
            return "Connection error: \(error)"
        } else {
            return "Not connected to Wyoming server"
        }
    }
}
