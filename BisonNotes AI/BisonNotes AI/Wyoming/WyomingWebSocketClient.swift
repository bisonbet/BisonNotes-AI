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
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    
    // MARK: - Initialization
    
    init(serverURL: URL) {
        self.serverURL = serverURL
        setupURLSession()
    }
    
    deinit {
        // Cancel WebSocket task synchronously
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
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
        
        print("🔌 Connecting to Wyoming server: \(serverURL)")
        
        return try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            
            guard let session = urlSession else {
                print("❌ No URL session available")
                continuation.resume(throwing: WyomingError.connectionFailed)
                return
            }
            
            // Create WebSocket connection
            webSocketTask = session.webSocketTask(with: serverURL)
            webSocketTask?.resume()
            
            // Start listening for messages
            startListening()
            
            // Give the WebSocket time to connect
            Task {
                do {
                    // Wait for connection to establish
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    
                    print("🔍 Testing if WebSocket connection is established...")
                    
                    // Check if we're still connected before sending message
                    if let task = self.webSocketTask, task.state == .running {
                        print("✅ WebSocket task is running")
                        
                        // First, just test the connection without sending a message
                        await MainActor.run {
                            self.isConnected = true
                            self.connectionError = nil
                            print("✅ WebSocket connection appears to be established")
                        }
                        
                        // Clear continuation first to prevent double resumption
                        await MainActor.run {
                            self.connectionContinuation = nil
                        }
                        
                        // Resume immediately since WebSocket is connected
                        continuation.resume()
                        
                        // Now try to send describe message (but don't wait for it in connection test)
                        Task {
                            do {
                                print("📤 Attempting to send describe message...")
                                try await self.sendMessage(WyomingMessageFactory.createDescribeMessage())
                                print("✅ Describe message sent successfully")
                            } catch {
                                print("⚠️ Failed to send describe message: \(error)")
                            }
                        }
                        
                    } else {
                        print("❌ WebSocket task is not running")
                        throw WyomingError.connectionFailed
                    }
                    
                } catch {
                    print("❌ Wyoming connection failed: \(error)")
                    await MainActor.run {
                        self.isConnected = false
                        self.connectionError = error.localizedDescription
                        
                        // Only resume if we still have the continuation 
                        // (it might have been resumed by handleConnectionError)
                        if self.connectionContinuation != nil {
                            self.connectionContinuation = nil
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    
    func disconnect() {
        print("🔌 Disconnecting from Wyoming server")
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        Task { @MainActor in
            isConnected = false
            connectionError = nil
        }
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
                    print("❌ Wyoming WebSocket receive error: \(error)")
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
            print("📦 Received binary data: \(data.count) bytes")
            
        @unknown default:
            print("⚠️ Unknown WebSocket message type")
        }
    }
    
    private func handleTextMessage(_ text: String) async {
        print("📨 Raw message received: \(text)")
        do {
            let wyomingMessage = try WyomingMessage.fromJSONString(text)
            print("📨 Parsed Wyoming message: \(wyomingMessage.type)")
            
            // Call registered handler for this message type
            if let handler = messageHandlers[wyomingMessage.type] {
                print("📨 Calling handler for message type: \(wyomingMessage.type)")
                handler(wyomingMessage)
            } else {
                print("⚠️ No handler registered for message type: \(wyomingMessage.type)")
            }
            
        } catch {
            print("❌ Failed to parse Wyoming message: \(error)")
            print("   Raw message: \(text)")
        }
    }
    
    private func handleConnectionError(_ error: Error) {
        isConnected = false
        connectionError = error.localizedDescription
        
        // If we have a pending connection continuation, fail it (but only once)
        if let continuation = connectionContinuation {
            connectionContinuation = nil // Clear it first to prevent double resumption
            continuation.resume(throwing: error)
        }
    }
    
    // MARK: - Message Sending
    
    func sendMessage(_ message: WyomingMessage) async throws {
        guard let webSocketTask = webSocketTask else {
            print("❌ No WebSocket task available")
            throw WyomingError.connectionFailed
        }
        
        // Don't require isConnected flag for the initial describe message
        if !isConnected && message.type != .describe {
            print("❌ Not connected to Wyoming server")
            throw WyomingError.connectionFailed
        }
        
        do {
            let jsonString = try message.toJSONString()
            print("📤 Sending Wyoming message: \(message.type)")
            print("📤 JSON payload: \(jsonString)")
            
            return try await withCheckedThrowingContinuation { continuation in
                webSocketTask.send(.string(jsonString)) { error in
                    if let error = error {
                        print("❌ Failed to send Wyoming message: \(error)")
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            
        } catch {
            print("❌ Failed to encode Wyoming message: \(error)")
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
                    print("❌ Failed to send audio data: \(error)")
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
            print("❌ Wyoming connection test failed: \(error)")
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
