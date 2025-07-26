# Design Document

## Overview

The improved summarization system will replace the current basic keyword-matching approach with intelligent natural language processing that creates meaningful summaries, extracts actionable tasks, and identifies time-sensitive reminders. The system will support multiple AI backends through a pluggable architecture, starting with enhanced Apple Intelligence processing and providing placeholders for future external services.

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                    SummariesView                            │
│  ┌─────────────────┐  ┌─────────────────┐                  │
│  │  UI Controls    │  │  Progress       │                  │
│  │  & Display      │  │  Indicators     │                  │
│  └─────────────────┘  └─────────────────┘                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 SummaryManager                              │
│  ┌─────────────────┐  ┌─────────────────┐                  │
│  │  Summary        │  │  Data           │                  │
│  │  Orchestration  │  │  Persistence    │                  │
│  └─────────────────┘  └─────────────────┘                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              SummarizationEngine                            │
│  ┌─────────────────┐  ┌─────────────────┐                  │
│  │  Content        │  │  AI Method      │                  │
│  │  Analysis       │  │  Selection      │                  │
│  └─────────────────┘  └─────────────────┘                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                AI Processing Layer                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │  Enhanced       │  │  AWS Bedrock    │  │  Whisper    │ │
│  │  Apple Intel.   │  │  (Future)       │  │  (Future)   │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Input Processing**: Transcript text is analyzed for content type and length
2. **Content Classification**: System determines if content is meeting, journal, technical, etc.
3. **AI Method Selection**: Based on user settings and content type
4. **Parallel Processing**: Summary, tasks, and reminders are extracted simultaneously
5. **Post-Processing**: Results are formatted, deduplicated, and validated
6. **Persistence**: Final results are saved with metadata and version info

## Components and Interfaces

### SummarizationEngine Protocol

```swift
protocol SummarizationEngine {
    func generateSummary(from text: String, contentType: ContentType) async throws -> String
    func extractTasks(from text: String) async throws -> [TaskItem]
    func extractReminders(from text: String) async throws -> [ReminderItem]
    var isAvailable: Bool { get }
    var name: String { get }
    var description: String { get }
}
```

### Enhanced Data Models

```swift
struct SummaryData {
    let id: UUID
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    let summary: String
    let tasks: [TaskItem]
    let reminders: [ReminderItem]
    let contentType: ContentType
    let aiMethod: String
    let generatedAt: Date
    let version: Int
}

struct TaskItem {
    let id: UUID
    let text: String
    let priority: Priority
    let timeReference: String?
    let category: TaskCategory
}

struct ReminderItem {
    let id: UUID
    let text: String
    let timeReference: TimeReference
    let urgency: Urgency
}

enum ContentType {
    case meeting
    case personalJournal
    case technical
    case general
}
```

### AI Processing Implementations

#### Enhanced Apple Intelligence Engine

- **Content Analysis**: Uses NLTagger with custom models for better sentence importance scoring
- **Semantic Clustering**: Groups related sentences before summarization
- **Template-Based Extraction**: Uses pattern matching with context awareness for tasks/reminders
- **Post-Processing**: Applies formatting rules and deduplication logic

#### Future External Engines

- **AWS Bedrock Engine**: Will use Claude/GPT models for advanced summarization
- **Whisper-Based Engine**: Will combine Whisper transcription with local LLM processing

## Data Models

### Enhanced SummaryData Structure

```swift
struct SummaryData: Codable, Identifiable {
    let id: UUID
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    
    // Core content
    let summary: String
    let tasks: [TaskItem]
    let reminders: [ReminderItem]
    
    // Metadata
    let contentType: ContentType
    let aiMethod: String
    let generatedAt: Date
    let version: Int
    let wordCount: Int
    let originalLength: Int
    let compressionRatio: Double
    
    // Quality metrics
    let confidence: Double
    let processingTime: TimeInterval
}
```

### Task and Reminder Models

```swift
struct TaskItem: Codable, Identifiable {
    let id: UUID
    let text: String
    let priority: Priority
    let timeReference: String?
    let category: TaskCategory
    let confidence: Double
    
    enum Priority: String, CaseIterable, Codable {
        case high = "High"
        case medium = "Medium" 
        case low = "Low"
    }
    
    enum TaskCategory: String, CaseIterable, Codable {
        case call = "Call"
        case meeting = "Meeting"
        case purchase = "Purchase"
        case research = "Research"
        case general = "General"
    }
}

struct ReminderItem: Codable, Identifiable {
    let id: UUID
    let text: String
    let timeReference: TimeReference
    let urgency: Urgency
    let confidence: Double
    
    struct TimeReference: Codable {
        let originalText: String
        let parsedDate: Date?
        let relativeTime: String?
        let isSpecific: Bool
    }
    
    enum Urgency: String, CaseIterable, Codable {
        case immediate = "Immediate"
        case today = "Today"
        case thisWeek = "This Week"
        case later = "Later"
    }
}
```

## Error Handling

### Error Types

```swift
enum SummarizationError: Error, LocalizedError {
    case transcriptTooShort
    case transcriptTooLong
    case aiServiceUnavailable
    case processingTimeout
    case insufficientContent
    case networkError
    case quotaExceeded
    
    var errorDescription: String? {
        switch self {
        case .transcriptTooShort:
            return "Transcript is too short to summarize effectively"
        case .transcriptTooLong:
            return "Transcript exceeds maximum length for processing"
        case .aiServiceUnavailable:
            return "Selected AI service is currently unavailable"
        case .processingTimeout:
            return "Summarization took too long and was cancelled"
        case .insufficientContent:
            return "Not enough meaningful content found for summarization"
        case .networkError:
            return "Network error occurred during processing"
        case .quotaExceeded:
            return "AI service quota exceeded, please try again later"
        }
    }
}
```

### Fallback Strategy

1. **Primary Method Fails**: Automatically retry with basic Apple Intelligence
2. **All Methods Fail**: Return structured error with partial results if available
3. **Timeout Handling**: Cancel long-running operations and provide user feedback
4. **Graceful Degradation**: Show existing summaries even if regeneration fails

## Testing Strategy

### Unit Tests

- **Content Classification**: Test detection of meeting vs journal vs technical content
- **Task Extraction**: Verify proper formatting and deduplication of tasks
- **Reminder Processing**: Test time reference parsing and urgency classification
- **Error Handling**: Validate all error conditions and fallback behaviors

### Integration Tests

- **End-to-End Flow**: Test complete summarization pipeline with real audio files
- **AI Engine Switching**: Verify seamless switching between different AI methods
- **Data Persistence**: Test saving and loading of enhanced summary data
- **Performance**: Measure processing time for various transcript lengths

### User Acceptance Tests

- **Summary Quality**: Compare new summaries with old keyword-based approach
- **Task Actionability**: Verify extracted tasks are clear and actionable
- **Reminder Usefulness**: Test that reminders contain proper time context
- **UI Responsiveness**: Ensure smooth user experience during processing

## Performance Considerations

### Processing Optimization

- **Chunked Processing**: Break large transcripts into manageable segments
- **Parallel Execution**: Process summary, tasks, and reminders simultaneously
- **Caching**: Cache intermediate results to speed up regeneration
- **Background Processing**: Use background queues for heavy AI processing

### Memory Management

- **Streaming Processing**: Process large texts without loading entirely into memory
- **Result Pagination**: Limit number of tasks/reminders to prevent memory issues
- **Cleanup**: Properly dispose of AI processing resources after use

### User Experience

- **Progress Indicators**: Show detailed progress for long-running operations
- **Cancellation**: Allow users to cancel processing if taking too long
- **Incremental Results**: Show partial results as they become available
- **Offline Handling**: Gracefully handle network unavailability for cloud services