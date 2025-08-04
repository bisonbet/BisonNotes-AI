//
//  DebugLogView.swift
//  Audio Journal
//
//  Simple in-app log viewer for debugging transcription issues
//

import SwiftUI

class DebugLogger: ObservableObject {
    @Published var logs: [String] = []
    static let shared = DebugLogger()
    
    private init() {}
    
    func log(_ message: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.logFormatter.string(from: Date())
            self.logs.append("[\(timestamp)] \(message)")
            
            // Keep only last 100 logs to prevent memory issues
            if self.logs.count > 100 {
                self.logs.removeFirst()
            }
        }
        
        // Also print to console
        print(message)
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

struct DebugLogView: View {
    @StateObject private var logger = DebugLogger.shared
    
    var body: some View {
        NavigationView {
            VStack {
                List(logger.logs, id: \.self) { log in
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                
                HStack {
                    Button("Clear Logs") {
                        logger.clear()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button("Copy All") {
                        let allLogs = logger.logs.joined(separator: "\n")
                        UIPasteboard.general.string = allLogs
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}