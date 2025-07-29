# Design Document

## Overview

This design outlines the restoration of the AI engine functionality that was previously commented out during refactoring. The system already has a well-structured AI engine architecture with multiple implementations including Enhanced Apple Intelligence, OpenAI, and Local LLM (Ollama) engines. The goal is to re-enable the complete AI engine infrastructure by uncommenting the initialization code and ensuring all components work together seamlessly.

## Architecture

### Current State Analysis

The codebase already contains:
- **SummarizationEngine Protocol**: Defines the interface for all AI engines
- **Multiple Engine Implementations**: 
  - `EnhancedAppleIntelligenceEngine`: Uses Apple's NLTagger for local processing
  - `OpenAISummarizationEngine`: Integrates with OpenAI's GPT models
  - `LocalLLMEngine`: Connects to Ollama for local LLM processing
  - Future engines: `AWSBedrockEngine`, `WhisperBasedEngine` (placeholder implementations)
- **Supporting Classes**: `TaskExtractor`, `ReminderExtractor`, `ContentAnalyzer`
- **Data Models**: `EnhancedSummaryData`, `TaskItem`, `ReminderItem`, `ContentType`
- **Engine Factory**: `AIEngineFactory` for creating and managing engines
- **Error Handling**: `SummarizationError` enum with comprehensive error cases

### Key Components

#### 1. SummaryManager Integration
The `SummaryManager` class has placeholder methods for engine management:
- `initializeEngines()` - Currently commented out
- `setEngine()` - Engine selection logic
- `getAvailableEngines()` - Returns available engine names
- Engine configuration methods

#### 2. Engine Lifecycle
- **Initialization**: Engines are created via `AIEngineFactory`
- **Configuration**: Each engine manages its own configuration from UserDefaults
- **Availability Checking**: Engines report their availability status
- **Processing**: Unified interface for summary generation, task extraction, and reminder extraction

#### 3. Processing Pipeline
1. **Content Classification**: Determine content type (meeting, journal, technical, general)
2. **Text Chunking**: Handle large transcripts by splitting into manageable chunks
3. **Parallel Processing**: Generate summaries, extract tasks and reminders
4. **Result Consolidation**: Combine and deduplicate results from chunked processing
5. **Quality Validation**: Confidence scoring and error handling

## Components and Interfaces

### Core Interfaces

```swift
protocol SummarizationEngine {
    var name: String { get }
    var description: String { get }
    var isAvailable: Bool { get }
    var version: String { get }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String
    func extractTasks(from text: String) async throws -> [TaskItem]
    func extractReminders(from text: String) async throws -> [ReminderItem]
    func classifyContent(_ text: String) async throws -> ContentType
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType)
}
```

### Engine Factory Pattern

```swift
class AIEngineFactory {
    static func createEngine(type: AIEngineType) -> SummarizationEngine
    static func getAvailableEngines() -> [AIEngineType]
    static func getAllEngines() -> [AIEngineType]
}
```

### Configuration Management

Each engine manages its own configuration:
- **Enhanced Apple Intelligence**: Uses built-in NLTagger, no external configuration needed
- **OpenAI**: Requires API key, model selection, temperature, max tokens
- **Local LLM**: Requires Ollama server URL, port, model name, connection settings

## Data Models

### Enhanced Summary Data Structure

```swift
struct EnhancedSummaryData {
    // Core content
    let summary: String
    let tasks: [TaskItem]
    let reminders: [ReminderItem]
    
    // Metadata
    let contentType: ContentType
    let aiMethod: String
    let confidence: Double
    let processingTime: TimeInterval
    let compressionRatio: Double
}
```

### Task and Reminder Models

```swift
struct TaskItem {
    let text: String
    let priority: Priority
    let category: TaskCategory
    let confidence: Double
    let timeReference: String?
}

struct ReminderItem {
    let text: String
    let timeReference: TimeReference
    let urgency: Urgency
    let confidence: Double
}
```

## Error Handling

### Comprehensive Error System

The system includes robust error handling with:
- **Service Availability**: Check if AI services are accessible
- **Network Errors**: Handle connectivity issues
- **Quota Limits**: Manage API rate limits and usage quotas
- **Processing Timeouts**: Handle long-running operations
- **Content Validation**: Ensure input meets minimum requirements

### Error Recovery Strategies

- **Graceful Degradation**: Fall back to simpler processing methods
- **Engine Switching**: Allow users to switch between available engines
- **Retry Logic**: Automatic retry for transient failures
- **User Feedback**: Clear error messages with actionable suggestions

## Testing Strategy

### Unit Testing

1. **Engine Interface Testing**
   - Test each engine's implementation of the SummarizationEngine protocol
   - Verify error handling for various failure scenarios
   - Test configuration management and validation

2. **Processing Pipeline Testing**
   - Test content classification accuracy
   - Verify task and reminder extraction quality
   - Test chunking and consolidation logic

3. **Integration Testing**
   - Test SummaryManager engine initialization
   - Verify engine switching functionality
   - Test end-to-end processing workflows

### Performance Testing

1. **Processing Speed**: Measure time for different content lengths
2. **Memory Usage**: Monitor memory consumption during processing
3. **Concurrent Processing**: Test multiple simultaneous requests
4. **Large Content Handling**: Test chunking with very long transcripts

### Quality Assurance

1. **Summary Quality**: Evaluate summary relevance and coherence
2. **Task Extraction Accuracy**: Verify task identification precision
3. **Reminder Detection**: Test time reference parsing accuracy
4. **Content Classification**: Validate content type detection

## Implementation Considerations

### Thread Safety

- All engine operations are async/await based
- SummaryManager uses `@MainActor` for UI updates
- Configuration updates are thread-safe

### Performance Optimization

- **Lazy Loading**: Engines are created only when needed
- **Caching**: Configuration and model data caching
- **Chunking Strategy**: Intelligent text splitting for large content
- **Parallel Processing**: Concurrent task and reminder extraction

### Privacy and Security

- **Local Processing**: Enhanced Apple Intelligence runs entirely on-device
- **API Key Security**: Secure storage of API credentials
- **Data Minimization**: Only necessary data sent to external services
- **User Control**: Clear indication of which engines use external services

### Scalability

- **Engine Extensibility**: Easy addition of new AI engines
- **Configuration Flexibility**: Per-engine configuration management
- **Resource Management**: Efficient memory and processing resource usage
- **Batch Processing**: Support for processing multiple recordings

## Migration Strategy

### Phase 1: Core Restoration
1. Uncomment `initializeEngines()` call in SummaryManager
2. Verify all existing engines initialize correctly
3. Test basic functionality with each engine

### Phase 2: Integration Testing
1. Test engine switching functionality
2. Verify configuration management
3. Test error handling and recovery

### Phase 3: Quality Assurance
1. Performance testing with various content types
2. User interface integration testing
3. End-to-end workflow validation

### Phase 4: User Experience
1. Settings UI integration
2. Engine status indicators
3. Error message improvements
4. Documentation updates