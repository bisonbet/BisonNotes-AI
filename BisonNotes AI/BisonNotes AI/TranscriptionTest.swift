//
//  TranscriptionTest.swift
//  Audio Journal
//
//  Test file for enhanced transcription functionality
//

import Foundation

#if DEBUG
class TranscriptionTest: ObservableObject {
    
    @Published var testResults: [String] = []
    
    static let shared = TranscriptionTest()
    
    private init() {}
    
    func testEnhancedTranscription() {
        log("🧪 Testing Enhanced Transcription Manager...")
        
        // Test configuration
        let testConfig: [String: Any] = [
            "maxChunkDuration": 300.0,
            "maxTranscriptionTime": 600.0,
            "chunkOverlap": 2.0,
            "enableEnhancedTranscription": true
        ]
        
        // Set test configuration
        for (key, value) in testConfig {
            if let doubleValue = value as? Double {
                UserDefaults.standard.set(doubleValue, forKey: key)
            } else if let boolValue = value as? Bool {
                UserDefaults.standard.set(boolValue, forKey: key)
            }
        }
        
        // Test chunk calculation
        testChunkCalculation()
        
        // Test duration formatting
        testDurationFormatting()
        
        // Test progress calculation
        testProgressCalculation()
        
        log("✅ Enhanced Transcription tests completed")
    }
    
    private func testChunkCalculation() {
        log("  📊 Testing chunk calculation...")
        
        let testCases = [
            (duration: 1800.0, expectedChunks: 6), // 30 minutes
            (duration: 3600.0, expectedChunks: 12), // 60 minutes
            (duration: 7200.0, expectedChunks: 24)  // 120 minutes
        ]
        
        for testCase in testCases {
            let chunks = calculateChunks(duration: testCase.duration, maxChunkDuration: 300, overlap: 2.0)
            let actualChunks = chunks.count
            let passed = actualChunks == testCase.expectedChunks
            
            log("    \(passed ? "✅" : "❌") \(testCase.duration/60)min file: expected \(testCase.expectedChunks) chunks, got \(actualChunks)")
        }
    }
    
    private func testDurationFormatting() {
        log("  ⏱️ Testing duration formatting...")
        
        let testCases = [
            (seconds: 65.0, expected: "1:05"),
            (seconds: 3661.0, expected: "1:01:01"),
            (seconds: 3600.0, expected: "1:00:00")
        ]
        
        for testCase in testCases {
            let formatted = formatDuration(testCase.seconds)
            let passed = formatted == testCase.expected
            
            log("    \(passed ? "✅" : "❌") \(testCase.seconds)s: expected '\(testCase.expected)', got '\(formatted)'")
        }
    }
    
    private func testProgressCalculation() {
        log("  📈 Testing progress calculation...")
        
        let progress = TranscriptionProgress(
            currentChunk: 3,
            totalChunks: 12,
            processedDuration: 900,
            totalDuration: 3600,
            currentText: "Sample text",
            isComplete: false,
            error: nil
        )
        
        let expectedPercentage = 3.0 / 12.0
        let actualPercentage = progress.percentage
        let passed = abs(actualPercentage - expectedPercentage) < 0.01
        
        log("    \(passed ? "✅" : "❌") Progress: expected \(Int(expectedPercentage * 100))%, got \(Int(actualPercentage * 100))%")
    }
    
    // Helper functions for testing
    private func calculateChunks(duration: TimeInterval, maxChunkDuration: TimeInterval, overlap: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        var chunks: [(start: TimeInterval, end: TimeInterval)] = []
        var currentStart: TimeInterval = 0
        
        while currentStart < duration {
            let currentEnd = min(currentStart + maxChunkDuration, duration)
            chunks.append((start: currentStart, end: currentEnd))
            currentStart = currentEnd - overlap
        }
        
        return chunks
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    private func log(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            self.testResults.append(message)
        }
    }
}

// MARK: - Test Runner

extension TranscriptionTest {
    func runAllTests() {
        log("🚀 Starting Enhanced Transcription Tests...")
        log("=" * 50)
        
        testEnhancedTranscription()
        
        log("=" * 50)
        log("🎉 All tests completed!")
    }
}

// MARK: - String Extension for Test Output

extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}
#endif 