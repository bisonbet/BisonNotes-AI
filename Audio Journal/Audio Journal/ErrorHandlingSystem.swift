//
//  ErrorHandlingSystem.swift
//  Audio Journal
//
//  Comprehensive error handling and validation system for summarization
//

import Foundation
import SwiftUI
import os.log

// MARK: - Error Handler

class ErrorHandler: ObservableObject {
    
    @Published var currentError: AppError?
    @Published var showingErrorAlert = false
    @Published var errorHistory: [ErrorLogEntry] = []
    
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "ErrorHandler")
    private let maxHistoryCount = 100
    
    // MARK: - Error Handling Methods
    
    func handle(_ error: Error, context: String = "", showToUser: Bool = true) {
        let appError = AppError.from(error, context: context)
        
        // Log the error
        logError(appError, context: context)
        
        // Add to history
        addToHistory(appError, context: context)
        
        // Show to user if requested
        if showToUser {
            DispatchQueue.main.async {
                self.currentError = appError
                self.showingErrorAlert = true
            }
        }
    }
    
    func handleSummarizationError(_ error: SummarizationError, recordingName: String = "", showToUser: Bool = true) {
        let context = recordingName.isEmpty ? "Summarization" : "Summarization for \(recordingName)"
        handle(error, context: context, showToUser: showToUser)
    }
    
    func clearCurrentError() {
        currentError = nil
        showingErrorAlert = false
    }
    
    func clearErrorHistory() {
        errorHistory.removeAll()
    }
    
    // MARK: - Validation Methods
    
    func validateTranscriptForSummarization(_ text: String) -> ValidationResult {
        var issues: [ValidationIssue] = []
        var warnings: [ValidationWarning] = []
        
        print("🔍 [ErrorHandlingSystem] Validating transcript for summarization...")
        print("📝 Text length: \(text.count) characters")
        
        // Check if text is empty
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("❌ [ErrorHandlingSystem] Transcript is empty")
            issues.append(.emptyTranscript)
            return ValidationResult(isValid: false, issues: issues, warnings: warnings)
        }
        
        // Check minimum length
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        print("📊 [ErrorHandlingSystem] Word count: \(wordCount)")
        
        // If transcript has 50 words or less, it's valid (will be shown as-is)
        if wordCount <= 50 {
            print("✅ [ErrorHandlingSystem] Transcript has 50 words or less (\(wordCount) words) - will be shown as-is")
            return ValidationResult(isValid: true, issues: issues, warnings: warnings)
        }
        
        // For longer transcripts, check minimum length
        if wordCount < 10 {
            print("❌ [ErrorHandlingSystem] Transcript too short: \(wordCount) words")
            issues.append(.transcriptTooShort(wordCount: wordCount))
            return ValidationResult(isValid: false, issues: issues, warnings: warnings)
        }
        
        // Check maximum length - increased to allow chunking system to handle large transcripts
        if wordCount > 50000 {
            print("❌ [ErrorHandlingSystem] Transcript too long: \(wordCount) words")
            issues.append(.transcriptTooLong(wordCount: wordCount, maxWords: 50000))
            return ValidationResult(isValid: false, issues: issues, warnings: warnings)
        }
        
        // Add warnings for potential issues (only for transcripts longer than 50 words)
        if wordCount > 10000 {
            warnings.append(.longTranscript(wordCount: wordCount))
            print("⚠️ [ErrorHandlingSystem] Long transcript warning: \(wordCount) words")
        }
        
        if wordCount > 10000 {
            warnings.append(.longTranscript(wordCount: wordCount))
            print("⚠️ [ErrorHandlingSystem] Long transcript warning: \(wordCount) words")
        }
        
        // Check for repetitive content
        let isRepetitive = isContentRepetitive(text)
        if isRepetitive {
            warnings.append(.repetitiveContent)
            print("⚠️ [ErrorHandlingSystem] Content appears repetitive")
        }
        
        // Check for low-quality transcription indicators
        let hasLowQuality = hasLowQualityIndicators(text)
        if hasLowQuality {
            warnings.append(.lowQualityTranscription)
            print("⚠️ [ErrorHandlingSystem] Low quality transcription indicators detected")
        }
        
        let result = ValidationResult(isValid: true, issues: issues, warnings: warnings)
        print("✅ [ErrorHandlingSystem] Validation passed with \(warnings.count) warnings")
        return result
    }
    
    func validateSummaryQuality(_ summary: EnhancedSummaryData) -> SummaryQualityReport {
        var issues: [SummaryQualityIssue] = []
        var suggestions: [SummaryImprovement] = []
        var score: Double = 1.0
        
        // Check summary length
        if summary.summary.isEmpty {
            issues.append(.emptySummary)
            score -= 0.5
        } else if summary.summary.count < 50 {
            issues.append(.summaryTooShort(length: summary.summary.count))
            score -= 0.2
        }
        
        // Check confidence score
        if summary.confidence < 0.3 {
            issues.append(.lowConfidence(confidence: summary.confidence))
            score -= 0.3
        } else if summary.confidence < 0.6 {
            suggestions.append(.improveConfidence)
            score -= 0.1
        }
        
        // Check compression ratio
        if summary.compressionRatio > 0.8 {
            issues.append(.poorCompression(ratio: summary.compressionRatio))
            score -= 0.2
        }
        
        // Check task and reminder extraction
        if summary.tasks.isEmpty && summary.reminders.isEmpty {
            suggestions.append(.noActionItemsFound)
            score -= 0.1
        }
        
        // Check processing time
        if summary.processingTime > 30.0 {
            suggestions.append(.slowProcessing(time: summary.processingTime))
        }
        
        // Check for duplicate content
        if hasDuplicateContent(summary) {
            issues.append(.duplicateContent)
            score -= 0.2
        }
        
        let qualityLevel = determineQualityLevel(score: max(0.0, score))
        
        return SummaryQualityReport(
            qualityLevel: qualityLevel,
            score: score,
            issues: issues,
            suggestions: suggestions,
            summary: summary
        )
    }
    
    // MARK: - Recovery Methods
    
    func suggestRecoveryActions(for error: AppError) -> [RecoveryAction] {
        switch error {
        case .summarization(let summaryError):
            return suggestSummarizationRecovery(summaryError)
        case .validation(let validationError):
            return suggestValidationRecovery(validationError)
        case .network(let networkError):
            return suggestNetworkRecovery(networkError)
        case .storage(let storageError):
            return suggestStorageRecovery(storageError)
        case .system(let systemError):
            return suggestSystemRecovery(systemError)
        }
    }
    
    // MARK: - Private Helper Methods
    
    private func logError(_ error: AppError, context: String) {
        let logMessage = "[\(context)] \(error.localizedDescription)"
        
        switch error.severity {
        case .low:
            logger.info("\(logMessage)")
        case .medium:
            logger.notice("\(logMessage)")
        case .high:
            logger.error("\(logMessage)")
        case .critical:
            logger.fault("\(logMessage)")
        }
    }
    
    private func addToHistory(_ error: AppError, context: String) {
        let entry = ErrorLogEntry(
            error: error,
            context: context,
            timestamp: Date()
        )
        
        errorHistory.insert(entry, at: 0)
        
        // Limit history size
        if errorHistory.count > maxHistoryCount {
            errorHistory.removeLast()
        }
    }
    
    private func isContentRepetitive(_ text: String) -> Bool {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard sentences.count > 3 else { return false }
        
        let uniqueSentences = Set(sentences.map { $0.lowercased() })
        let repetitionRatio = Double(uniqueSentences.count) / Double(sentences.count)
        
        return repetitionRatio < 0.7 // If less than 70% of sentences are unique
    }
    
    private func hasLowQualityIndicators(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let indicators = ["um", "uh", "like", "you know", "[inaudible]", "[unclear]", "..."]
        
        var indicatorCount = 0
        for indicator in indicators {
            indicatorCount += lowercased.components(separatedBy: indicator).count - 1
        }
        
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).count
        let indicatorRatio = Double(indicatorCount) / Double(wordCount)
        
        return indicatorRatio > 0.1 // If more than 10% of content is low-quality indicators
    }
    
    private func hasDuplicateContent(_ summary: EnhancedSummaryData) -> Bool {
        // Check for duplicate tasks
        let taskTexts = summary.tasks.map { $0.text.lowercased() }
        if Set(taskTexts).count != taskTexts.count {
            return true
        }
        
        // Check for duplicate reminders
        let reminderTexts = summary.reminders.map { $0.text.lowercased() }
        if Set(reminderTexts).count != reminderTexts.count {
            return true
        }
        
        return false
    }
    
    private func determineQualityLevel(score: Double) -> SummaryQualityLevel {
        switch score {
        case 0.9...1.0: return .excellent
        case 0.7..<0.9: return .good
        case 0.5..<0.7: return .fair
        case 0.3..<0.5: return .poor
        default: return .unacceptable
        }
    }
    
    // MARK: - Recovery Suggestion Methods
    
    private func suggestSummarizationRecovery(_ error: SummarizationError) -> [RecoveryAction] {
        switch error {
        case .transcriptTooShort:
            return [
                .retryWithLongerContent,
                .adjustSettings,
                .contactSupport
            ]
        case .transcriptTooLong:
            return [
                .splitContent,
                .adjustSettings,
                .tryDifferentEngine
            ]
        case .aiServiceUnavailable:
            return [
                .tryDifferentEngine,
                .retryLater,
                .checkNetworkConnection
            ]
        case .processingTimeout:
            return [
                .retryWithShorterContent,
                .checkNetworkConnection,
                .tryDifferentEngine
            ]
        case .insufficientContent:
            return [
                .retryWithBetterContent,
                .adjustSettings,
                .manualSummary
            ]
        case .networkError:
            return [
                .checkNetworkConnection,
                .retryLater,
                .tryOfflineMode
            ]
        case .quotaExceeded:
            return [
                .waitAndRetry,
                .tryDifferentEngine,
                .upgradeAccount
            ]
        default:
            return [
                .retryOperation,
                .tryDifferentEngine,
                .contactSupport
            ]
        }
    }
    
    private func suggestValidationRecovery(_ error: ValidationError) -> [RecoveryAction] {
        return [
            .checkInput,
            .adjustSettings,
            .retryOperation
        ]
    }
    
    private func suggestNetworkRecovery(_ error: NetworkError) -> [RecoveryAction] {
        return [
            .checkNetworkConnection,
            .retryLater,
            .tryOfflineMode
        ]
    }
    
    private func suggestStorageRecovery(_ error: StorageError) -> [RecoveryAction] {
        return [
            .freeUpSpace,
            .checkPermissions,
            .restartApp
        ]
    }
    
    private func suggestSystemRecovery(_ error: SystemError) -> [RecoveryAction] {
        return [
            .restartApp,
            .updateApp,
            .contactSupport
        ]
    }
}

// MARK: - Error Types

enum AppError: LocalizedError, Identifiable {
    case summarization(SummarizationError)
    case validation(ValidationError)
    case network(NetworkError)
    case storage(StorageError)
    case system(SystemError)
    
    var id: String {
        return "\(type(of: self))_\(UUID().uuidString)"
    }
    
    var errorDescription: String? {
        switch self {
        case .summarization(let error):
            return error.localizedDescription
        case .validation(let error):
            return error.localizedDescription
        case .network(let error):
            return error.localizedDescription
        case .storage(let error):
            return error.localizedDescription
        case .system(let error):
            return error.localizedDescription
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .summarization(let error):
            return error.recoverySuggestion
        case .validation(let error):
            return error.recoverySuggestion
        case .network(let error):
            return error.recoverySuggestion
        case .storage(let error):
            return error.recoverySuggestion
        case .system(let error):
            return error.recoverySuggestion
        }
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .summarization(let error):
            return error.severity
        case .validation:
            return .medium
        case .network:
            return .medium
        case .storage:
            return .high
        case .system:
            return .critical
        }
    }
    
    static func from(_ error: Error, context: String = "") -> AppError {
        if let summaryError = error as? SummarizationError {
            return .summarization(summaryError)
        } else if let validationError = error as? ValidationError {
            return .validation(validationError)
        } else if let networkError = error as? NetworkError {
            return .network(networkError)
        } else if let storageError = error as? StorageError {
            return .storage(storageError)
        } else {
            return .system(.unknown(underlying: error, context: context))
        }
    }
}

enum ValidationError: LocalizedError {
    case emptyInput
    case invalidFormat
    case missingRequiredField(field: String)
    case valueOutOfRange(value: Any, range: String)
    
    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Input cannot be empty"
        case .invalidFormat:
            return "Input format is invalid"
        case .missingRequiredField(let field):
            return "Required field '\(field)' is missing"
        case .valueOutOfRange(let value, let range):
            return "Value '\(value)' is outside valid range: \(range)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .emptyInput:
            return "Please provide valid input and try again"
        case .invalidFormat:
            return "Check the input format and correct any issues"
        case .missingRequiredField:
            return "Fill in all required fields before proceeding"
        case .valueOutOfRange:
            return "Adjust the value to be within the valid range"
        }
    }
}

enum NetworkError: LocalizedError {
    case noConnection
    case timeout
    case serverError(code: Int)
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .noConnection:
            return "No internet connection available"
        case .timeout:
            return "Network request timed out"
        case .serverError(let code):
            return "Server error (code: \(code))"
        case .invalidResponse:
            return "Invalid response from server"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .noConnection:
            return "Check your internet connection and try again"
        case .timeout:
            return "Check your connection speed and retry"
        case .serverError:
            return "The service is temporarily unavailable. Please try again later"
        case .invalidResponse:
            return "There was a communication error. Please try again"
        }
    }
}

enum StorageError: LocalizedError {
    case insufficientSpace
    case permissionDenied
    case corruptedData
    case fileNotFound(path: String)
    
    var errorDescription: String? {
        switch self {
        case .insufficientSpace:
            return "Insufficient storage space"
        case .permissionDenied:
            return "Storage permission denied"
        case .corruptedData:
            return "Data corruption detected"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .insufficientSpace:
            return "Free up storage space and try again"
        case .permissionDenied:
            return "Grant storage permissions in Settings"
        case .corruptedData:
            return "The data may be corrupted. Try regenerating or contact support"
        case .fileNotFound:
            return "The file may have been moved or deleted. Try refreshing"
        }
    }
}

enum SystemError: LocalizedError {
    case memoryPressure
    case memoryError
    case networkError
    case storageError
    case unknown(underlying: Error, context: String)
    case configurationError(message: String)
    
    var errorDescription: String? {
        switch self {
        case .memoryPressure:
            return "System is low on memory"
        case .memoryError:
            return "Memory allocation error"
        case .networkError:
            return "Network connectivity error"
        case .storageError:
            return "Storage access error"
        case .unknown(let error, let context):
            return "Unexpected error in \(context): \(error.localizedDescription)"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .memoryPressure:
            return "Close other apps and try again"
        case .memoryError:
            return "Restart the app to free memory"
        case .networkError:
            return "Check your internet connection"
        case .storageError:
            return "Check available storage space"
        case .unknown:
            return "Please try again or contact support if the problem persists"
        case .configurationError:
            return "Check app settings and configuration"
        }
    }
}

enum ErrorSeverity: Int, CaseIterable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4
    
    var description: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
    
    var color: Color {
        switch self {
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        case .critical: return .purple
        }
    }
}

// MARK: - Validation Types

struct ValidationResult {
    let isValid: Bool
    let issues: [ValidationIssue]
    let warnings: [ValidationWarning]
    
    var hasWarnings: Bool {
        return !warnings.isEmpty
    }
    
    var summary: String {
        if !isValid {
            return "Validation failed: \(issues.count) issue(s)"
        } else if hasWarnings {
            return "Validation passed with \(warnings.count) warning(s)"
        } else {
            return "Validation passed"
        }
    }
}

enum ValidationIssue: LocalizedError {
    case emptyTranscript
    case transcriptTooShort(wordCount: Int)
    case transcriptTooLong(wordCount: Int, maxWords: Int)
    
    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Transcript is empty"
        case .transcriptTooShort(let count):
            return "Transcript is too short (\(count) words, minimum 10 required)"
        case .transcriptTooLong(let count, let max):
            return "Transcript is too long (\(count) words, maximum \(max) allowed)"
        }
    }
}

enum ValidationWarning {
    case shortTranscript(wordCount: Int)
    case longTranscript(wordCount: Int)
    case repetitiveContent
    case lowQualityTranscription
    
    var description: String {
        switch self {
        case .shortTranscript(let count):
            return "Short transcript (\(count) words) may produce limited summary"
        case .longTranscript(let count):
            return "Long transcript (\(count) words) may take longer to process"
        case .repetitiveContent:
            return "Content appears repetitive, summary quality may be affected"
        case .lowQualityTranscription:
            return "Transcription quality appears low, consider re-recording"
        }
    }
}

// MARK: - Quality Assessment Types

struct SummaryQualityReport {
    let qualityLevel: SummaryQualityLevel
    let score: Double
    let issues: [SummaryQualityIssue]
    let suggestions: [SummaryImprovement]
    let summary: EnhancedSummaryData
    
    var formattedScore: String {
        return String(format: "%.1f%%", score * 100)
    }
    
    var overallAssessment: String {
        return "\(qualityLevel.description) (\(formattedScore))"
    }
}

enum SummaryQualityLevel: CaseIterable {
    case excellent
    case good
    case fair
    case poor
    case unacceptable
    
    var description: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        case .unacceptable: return "Unacceptable"
        }
    }
    
    var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .orange
        case .poor: return .red
        case .unacceptable: return .purple
        }
    }
}

enum SummaryQualityIssue {
    case emptySummary
    case summaryTooShort(length: Int)
    case lowConfidence(confidence: Double)
    case poorCompression(ratio: Double)
    case duplicateContent
    
    var description: String {
        switch self {
        case .emptySummary:
            return "Summary is empty"
        case .summaryTooShort(let length):
            return "Summary is very short (\(length) characters)"
        case .lowConfidence(let confidence):
            return "Low confidence score (\(String(format: "%.1f%%", confidence * 100)))"
        case .poorCompression(let ratio):
            return "Poor compression ratio (\(String(format: "%.1f%%", ratio * 100)))"
        case .duplicateContent:
            return "Duplicate content detected"
        }
    }
}

enum SummaryImprovement {
    case improveConfidence
    case noActionItemsFound
    case slowProcessing(time: TimeInterval)
    
    var description: String {
        switch self {
        case .improveConfidence:
            return "Consider using a different AI engine for better confidence"
        case .noActionItemsFound:
            return "No tasks or reminders were extracted"
        case .slowProcessing(let time):
            return "Processing took \(String(format: "%.1f", time))s, consider shorter content"
        }
    }
}

// MARK: - Recovery Actions

enum RecoveryAction: CaseIterable {
    case retryOperation
    case retryWithLongerContent
    case retryWithShorterContent
    case retryWithBetterContent
    case splitContent
    case adjustSettings
    case tryDifferentEngine
    case retryLater
    case checkNetworkConnection
    case tryOfflineMode
    case waitAndRetry
    case upgradeAccount
    case checkInput
    case freeUpSpace
    case checkPermissions
    case restartApp
    case updateApp
    case manualSummary
    case contactSupport
    
    var title: String {
        switch self {
        case .retryOperation: return "Retry"
        case .retryWithLongerContent: return "Use Longer Content"
        case .retryWithShorterContent: return "Use Shorter Content"
        case .retryWithBetterContent: return "Improve Content Quality"
        case .splitContent: return "Split Content"
        case .adjustSettings: return "Adjust Settings"
        case .tryDifferentEngine: return "Try Different AI Engine"
        case .retryLater: return "Try Again Later"
        case .checkNetworkConnection: return "Check Network"
        case .tryOfflineMode: return "Use Offline Mode"
        case .waitAndRetry: return "Wait and Retry"
        case .upgradeAccount: return "Upgrade Account"
        case .checkInput: return "Check Input"
        case .freeUpSpace: return "Free Up Space"
        case .checkPermissions: return "Check Permissions"
        case .restartApp: return "Restart App"
        case .updateApp: return "Update App"
        case .manualSummary: return "Create Manual Summary"
        case .contactSupport: return "Contact Support"
        }
    }
    
    var description: String {
        switch self {
        case .retryOperation: return "Try the operation again"
        case .retryWithLongerContent: return "Record longer audio with more content"
        case .retryWithShorterContent: return "Use shorter content that's easier to process"
        case .retryWithBetterContent: return "Ensure clear speech and meaningful content"
        case .splitContent: return "Break large content into smaller parts"
        case .adjustSettings: return "Modify app settings for better results"
        case .tryDifferentEngine: return "Switch to a different AI summarization engine"
        case .retryLater: return "Wait a moment and try again"
        case .checkNetworkConnection: return "Verify your internet connection"
        case .tryOfflineMode: return "Use local processing instead"
        case .waitAndRetry: return "Wait for quota reset and try again"
        case .upgradeAccount: return "Upgrade to premium for higher limits"
        case .checkInput: return "Verify your input is correct"
        case .freeUpSpace: return "Delete files to free up storage space"
        case .checkPermissions: return "Grant necessary app permissions"
        case .restartApp: return "Close and reopen the app"
        case .updateApp: return "Install the latest app version"
        case .manualSummary: return "Create a summary manually"
        case .contactSupport: return "Get help from our support team"
        }
    }
}

// MARK: - Error Log Entry

struct ErrorLogEntry: Identifiable {
    let id = UUID()
    let error: AppError
    let context: String
    let timestamp: Date
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }
}

// MARK: - Extensions

extension SummarizationError {
    var severity: ErrorSeverity {
        switch self {
        case .transcriptTooShort, .insufficientContent:
            return .low
        case .transcriptTooLong, .processingTimeout:
            return .medium
        case .aiServiceUnavailable, .networkError:
            return .high
        case .quotaExceeded, .processingFailed:
            return .critical
        default:
            return .medium
        }
    }
}