//
//  WyomingTCPClient.swift
//  Audio Journal
//
//  TCP client for Wyoming protocol communication (not WebSocket)
//

import Foundation
import Network

// MARK: - Timeout Helper

func wyomingTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw WyomingError.timeout
        }
        
        guard let result = try await group.next() else {
            throw WyomingError.timeout
        }
        
        group.cancelAll()
        return result
    }
}

actor ConnectionActor {
    var connection: NWConnection?
    
    func setConnection(_ connection: NWConnection?) {
        self.connection = connection
    }
    
    func getConnection() -> NWConnection? {
        return connection
    }
    
    func cancelConnection() {
        connection?.cancel()
        connection = nil
    }
}

@MainActor
class WyomingTCPClient: ObservableObject {
    
    // MARK: - Properties
    
    @Published var isConnected = false
    @Published var connectionError: String?
    
    private let connectionActor = ConnectionActor()
    private let serverHost: String
    private let serverPort: Int
    private var messageHandlers: [WyomingMessageType: (WyomingMessage) -> Void] = [:]
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    
    // MARK: - Initialization
    
    init(host: String, port: Int) {
        self.serverHost = host
        self.serverPort = port
    }
    
    deinit {
        print("🗑️ WyomingTCPClient deinit")
        
        // Clear any pending continuation
        if let continuation = connectionContinuation {
            connectionContinuation = nil
            continuation.resume(throwing: WyomingError.connectionFailed)
        }
        
        // Clear handlers to break potential retain cycles
        messageHandlers.removeAll()
        
        // Cancel connection synchronously without Task
        let actor = connectionActor
        Task.detached {
            await actor.cancelConnection()
        }
    }
    
    // MARK: - Connection Management
    
    func connect() async throws {
        guard !isConnected else { return }
        
        print("🔌 Connecting to Wyoming TCP server: \(serverHost):\(serverPort)")
        
        // Create TCP connection
        let host = NWEndpoint.Host(serverHost)
        let port = NWEndpoint.Port(integerLiteral: UInt16(serverPort))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        
        let connection = NWConnection(to: endpoint, using: .tcp)
        await connectionActor.setConnection(connection)
        
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: WyomingError.connectionFailed)
                return
            }
            
            self.connectionContinuation = continuation
            
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    await self?.handleConnectionStateUpdate(state)
                }
            }
            
            // Start the connection
            let queue = DispatchQueue(label: "wyoming-tcp")
            connection.start(queue: queue)
            
            // Start receiving data
            self.startReceiving()
        }
    }
    
    private func handleConnectionStateUpdate(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            print("✅ Wyoming TCP connection established")
            isConnected = true
            connectionError = nil
            
            // Resume connection continuation if waiting
            if let continuation = connectionContinuation {
                connectionContinuation = nil
                continuation.resume()
            }
            
        case .failed(let error):
            print("❌ Wyoming TCP connection failed: \(error)")
            isConnected = false
            connectionError = error.localizedDescription
            
            if let continuation = connectionContinuation {
                connectionContinuation = nil
                continuation.resume(throwing: error)
            }
            
        case .cancelled:
            print("🔌 Wyoming TCP connection cancelled")
            isConnected = false
            
        case .waiting(let error):
            print("⏳ Wyoming TCP connection waiting: \(error)")
            
        case .preparing:
            print("🔄 Wyoming TCP connection preparing...")
            
        case .setup:
            print("🔧 Wyoming TCP connection setup...")
            
        @unknown default:
            print("⚠️ Unknown Wyoming TCP connection state")
        }
    }
    
    nonisolated func disconnect() {
        print("🔌 Disconnecting from Wyoming TCP server")
        
        Task {
            await connectionActor.cancelConnection()
            
            await MainActor.run {
                // Clear any pending continuation
                if let continuation = self.connectionContinuation {
                    self.connectionContinuation = nil
                    continuation.resume(throwing: WyomingError.connectionFailed)
                }
                
                self.isConnected = false
                self.connectionError = nil
                
                // Clear handlers to break retain cycles
                self.messageHandlers.removeAll()
            }
        }
    }
    
    // MARK: - Message Sending
    
    func sendMessage(_ message: WyomingMessage) async throws {
        guard let connection = await connectionActor.getConnection(), isConnected else {
            throw WyomingError.connectionFailed
        }
        
        let jsonString = try message.toJSONString()
        
        // Comment out individual message logging for audio chunks to reduce log volume
        if message.type != .audioChunk {
            print("📤 Sending Wyoming TCP message: \(message.type)")
            
            // Truncate JSON payload logging to avoid massive logs
            if jsonString.count > 200 {
                let truncated = String(jsonString.prefix(200)) + "... (\(jsonString.count) chars total)"
                print("📤 JSON payload: \(truncated)")
            } else {
                print("📤 JSON payload: \(jsonString)")
            }
        }
        // Commented out for audio chunks:
        // print("📤 Sending Wyoming TCP message: \(message.type)")
        // print("📤 JSON payload: \(truncated or full JSON)")
        
        
        // Wyoming protocol uses JSONL (JSON Lines) - each message on a separate line
        let messageData = (jsonString + "\n").data(using: .utf8)!
        
        // Send JSON first
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: messageData, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send Wyoming TCP message: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        
        // If there's a payload (like for audio chunks), send it separately
        if let payload = message.payload {
            // print("📤 Sending binary payload: \(payload.count) bytes")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error = error {
                        print("❌ Failed to send Wyoming binary payload: \(error)")
                        continuation.resume(throwing: error)
                    } else {
                        // print("✅ Wyoming binary payload sent successfully")
                        continuation.resume()
                    }
                })
            }
        } else {
            print("✅ Wyoming TCP message sent successfully")
        }
    }
    
    func sendAudioData(_ audioData: Data) async throws {
        guard let connection = await connectionActor.getConnection(), isConnected else {
            throw WyomingError.connectionFailed
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: audioData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    // Optimized batch audio data sending with flow control and error recovery
    func sendAudioDataBatch(_ audioDataChunks: [Data], progressCallback: @escaping (Int, Int) -> Void) async throws {
        guard let connection = await connectionActor.getConnection(), isConnected else {
            throw WyomingError.connectionFailed
        }
        
        let totalChunks = audioDataChunks.count
        var sentChunks = 0
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 5
        
        print("🔄 Starting to send \(totalChunks) chunks to Wyoming server...")
        
        for (index, chunk) in audioDataChunks.enumerated() {
            print("📤 Sending chunk \(index + 1)/\(totalChunks) (\(chunk.count) bytes)")
            var chunkSent = false
            var retryCount = 0
            let maxRetries = 3
            
            while !chunkSent && retryCount < maxRetries {
                do {
                    // Add timeout protection for individual chunk sends
                    try await wyomingTimeout(seconds: 30) {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            connection.send(content: chunk, completion: .contentProcessed { error in
                                if let error = error {
                                    print("❌ Wyoming chunk \(index + 1) send error: \(error)")
                                    continuation.resume(throwing: error)
                                } else {
                                    continuation.resume()
                                }
                            })
                        }
                    }
                    
                    sentChunks += 1
                    chunkSent = true
                    consecutiveErrors = 0 // Reset error counter on success
                    print("✅ Chunk \(index + 1) sent successfully")
                    
                } catch {
                    retryCount += 1
                    consecutiveErrors += 1
                    
                    print("⚠️ Wyoming chunk \(index + 1) send failed (attempt \(retryCount)/\(maxRetries)): \(error)")
                    
                    if consecutiveErrors >= maxConsecutiveErrors {
                        print("❌ Too many consecutive Wyoming streaming errors (\(consecutiveErrors)), aborting")
                        throw WyomingError.serverError("Network streaming failed after \(consecutiveErrors) consecutive errors")
                    }
                    
                    if retryCount < maxRetries {
                        // Exponential backoff: 100ms, 200ms, 400ms
                        let delayMs = 100 * (1 << (retryCount - 1))
                        try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    } else {
                        print("❌ Wyoming chunk \(index + 1) failed after \(maxRetries) retries")
                        throw error
                    }
                }
            }
            
            // Call progress callback every 50 chunks or at completion
            if (index + 1) % 50 == 0 || index == totalChunks - 1 {
                progressCallback(sentChunks, totalChunks)
            }
        }
    }
    
    // MARK: - Message Receiving
    
    private func startReceiving() {
        receiveNextMessage()
    }
    
    private func receiveNextMessage() {
        Task {
            guard let connection = await connectionActor.getConnection() else { return }
            
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let error = error {
                    print("❌ Wyoming TCP receive error: \(error)")
                    return
                }
                
                if let data = data, !data.isEmpty {
                    Task { @MainActor in
                        await self?.handleReceivedData(data)
                    }
                }
                
                if !isComplete {
                    Task { @MainActor in
                        self?.receiveNextMessage()
                    }
                }
            }
        }
    }
    
    private func handleReceivedData(_ data: Data) async {
        guard let text = String(data: data, encoding: .utf8) else {
            print("❌ Failed to decode received data as UTF-8")
            return
        }
        
        // Truncate raw TCP data logging to keep logs manageable
        if text.count > 200 {
            let truncated = String(text.prefix(200)) + "... (\(text.count) chars total)"
            print("📨 Raw TCP data received: \(truncated)")
        } else {
            print("📨 Raw TCP data received: \(text)")
        }
        
        // Wyoming protocol uses JSONL - split by newlines
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLine.isEmpty {
                await handleTextMessage(trimmedLine)
            }
        }
    }
    
    private func handleTextMessage(_ text: String) async {
        // Truncate message line logging to keep logs manageable
        if text.count > 200 {
            let truncated = String(text.prefix(200)) + "... (\(text.count) chars total)"
            print("📨 Processing Wyoming message line: \(truncated)")
        } else {
            print("📨 Processing Wyoming message line: \(text)")
        }
        
        // First, try to parse as a Wyoming message with type
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
            // If it fails to parse as a Wyoming message, it might be raw transcript data
            print("📨 Received raw data (not a Wyoming message): \(text.prefix(100))...")
            
            // Try to parse as raw transcript JSON
            if let textData = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
               let transcriptText = json["text"] as? String {
                
                print("📝 Parsed raw transcript text: \(transcriptText.prefix(100))...")
                
                // Create a synthetic WyomingMessage for the transcript handler
                let transcriptData = WyomingTranscriptData(text: transcriptText, language: nil, confidence: nil)
                let syntheticMessage = WyomingMessage(type: .transcript, data: transcriptData)
                
                // Call the transcript handler directly
                if let handler = messageHandlers[.transcript] {
                    handler(syntheticMessage)
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
    
    func sendTranscribe(language: String? = "en", model: String? = nil) async throws {
        try await sendMessage(WyomingMessageFactory.createTranscribeMessage(language: language, model: model))
    }
    
    func sendAudioStart() async throws {
        try await sendMessage(WyomingMessageFactory.createAudioStartMessage())
    }
    
    func sendAudioStop() async throws {
        try await sendMessage(WyomingMessageFactory.createAudioStopMessage())
    }
    
    func sendAudioChunk(_ audioData: Data, rate: Int = 16000, width: Int = 16, channels: Int = 1) async throws {
        let message = WyomingMessageFactory.createAudioChunkMessage(audioData: audioData, rate: rate, width: width, channels: channels)
        try await sendMessage(message)
    }
    
    // MARK: - Connection Testing
    
    func testConnection() async -> Bool {
        do {
            try await connect()
            return isConnected
        } catch {
            print("❌ Wyoming TCP connection test failed: \(error)")
            return false
        }
    }
    
    // MARK: - Connection State
    
    var connectionStatus: String {
        if isConnected {
            return "Connected to Wyoming TCP server"
        } else if let error = connectionError {
            return "Connection error: \(error)"
        } else {
            return "Not connected to Wyoming TCP server"
        }
    }
}