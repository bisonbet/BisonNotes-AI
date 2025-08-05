//
//  WyomingTCPClient.swift
//  Audio Journal
//
//  TCP client for Wyoming protocol communication (not WebSocket)
//

import Foundation
import Network

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
        print("📤 Sending Wyoming TCP message: \(message.type)")
        print("📤 JSON payload: \(jsonString)")
        
        // Wyoming protocol uses JSONL (JSON Lines) - each message on a separate line
        let messageData = (jsonString + "\n").data(using: .utf8)!
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: messageData, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send Wyoming TCP message: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ Wyoming TCP message sent successfully")
                    continuation.resume()
                }
            })
        }
    }
    
    func sendAudioData(_ audioData: Data) async throws {
        guard let connection = await connectionActor.getConnection(), isConnected else {
            throw WyomingError.connectionFailed
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: audioData, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send Wyoming audio data: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
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
        
        print("📨 Raw TCP data received: \(text)")
        
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
        print("📨 Processing Wyoming message line: \(text)")
        
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
            // If it fails to parse as a Wyoming message, it might be raw data
            // This happens when the server sends data_length > 0
            print("📨 Received raw data (not a Wyoming message): \(text.prefix(100))...")
            
            // For now, we'll skip raw data. In a full implementation, 
            // we'd need to associate this with the previous message that had data_length
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