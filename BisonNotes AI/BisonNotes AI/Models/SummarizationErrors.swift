import Foundation

// MARK: - Summarization Errors

enum SummarizationError: Error, LocalizedError {
    case transcriptTooShort
    case transcriptTooLong(maxLength: Int)
    case aiServiceUnavailable(service: String)
    case processingTimeout
    case insufficientContent
    case networkError(underlying: Error)
    case quotaExceeded
    case invalidInput
    case processingFailed(reason: String)
    
    var errorDescription: String? {
        switch self {
        case .transcriptTooShort:
            return "Transcript is too short to summarize effectively (minimum 50 words required)"
        case .transcriptTooLong(let maxLength):
            return "Transcript exceeds maximum length of \(maxLength) words for processing"
        case .aiServiceUnavailable(let service):
            return "\(service) is currently unavailable. Please try again later."
        case .processingTimeout:
            return "Summarization took too long and was cancelled. Try with a shorter recording."
        case .insufficientContent:
            return "Not enough meaningful content found for summarization"
        case .networkError(let underlying):
            return "Network error occurred: \(underlying.localizedDescription)"
        case .quotaExceeded:
            return "AI service quota exceeded. Please try again later."
        case .invalidInput:
            return "Invalid input provided for summarization"
        case .processingFailed(let reason):
            return "Summarization failed: \(reason)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .transcriptTooShort:
            return "Try recording a longer audio clip with more content."
        case .transcriptTooLong:
            return "Try breaking the recording into smaller segments."
        case .aiServiceUnavailable:
            return "Switch to a different AI method in settings or try again later."
        case .processingTimeout:
            return "Try with a shorter recording or check your internet connection."
        case .insufficientContent:
            return "Ensure your recording contains clear speech with actionable content."
        case .networkError:
            return "Check your internet connection and try again."
        case .quotaExceeded:
            return "Wait a few minutes before trying again, or switch to a different AI method."
        case .invalidInput:
            return "Please ensure the recording was transcribed properly."
        case .processingFailed:
            return "Try regenerating the summary or switch to a different AI method."
        }
    }
}