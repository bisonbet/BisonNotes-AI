# Requirements Document

## Introduction

The current summarization system in the Audio Journal app uses basic keyword matching that simply returns sentences from the original transcript rather than creating meaningful summaries. Users are experiencing poor quality summaries that just repeat the transcript, and tasks/reminders are returned as long, unprocessed sentences rather than actionable items. This feature will redesign the summarization system to provide intelligent, concise summaries with properly extracted tasks and reminders using advanced natural language processing.

## Requirements

### Requirement 1

**User Story:** As a user, I want to receive concise, meaningful summaries of my audio recordings, so that I can quickly understand the key points without reading the full transcript.

#### Acceptance Criteria

1. WHEN a user generates a summary THEN the system SHALL create a condensed version that captures the main themes and key points
2. WHEN the summary is generated THEN it SHALL be significantly shorter than the original transcript (target 10-20% of original length)
3. WHEN the summary contains multiple topics THEN the system SHALL organize them into coherent paragraphs or sections
4. WHEN the original transcript is empty or very short THEN the system SHALL provide an appropriate message rather than attempting summarization

### Requirement 2

**User Story:** As a user, I want tasks to be extracted as clear, actionable bullet points, so that I can easily see what I need to do without parsing through long sentences.

#### Acceptance Criteria

1. WHEN the system extracts tasks THEN it SHALL format them as concise bullet points starting with action verbs
2. WHEN a task contains timing information THEN the system SHALL preserve and highlight the time reference
3. WHEN multiple similar tasks are found THEN the system SHALL consolidate them to avoid duplication
4. WHEN no clear tasks are identified THEN the system SHALL return an empty list rather than generic statements
5. WHEN tasks are extracted THEN they SHALL be limited to a maximum of 10 items to maintain focus

### Requirement 3

**User Story:** As a user, I want reminders to be extracted with specific time references and context, so that I can set up appropriate notifications and remember important time-sensitive items.

#### Acceptance Criteria

1. WHEN the system extracts reminders THEN it SHALL identify and preserve specific time references (dates, times, relative timing)
2. WHEN a reminder has a deadline THEN the system SHALL format it to clearly show the time constraint
3. WHEN reminders are found THEN they SHALL be formatted as actionable items with clear context
4. WHEN no time-sensitive items are identified THEN the system SHALL return an empty list
5. WHEN multiple reminders reference the same event THEN the system SHALL consolidate them into a single item

### Requirement 4

**User Story:** As a user, I want to choose from different AI summarization methods based on my needs and available services, so that I can get the best quality summaries for my use case.

#### Acceptance Criteria

1. WHEN the user accesses summarization settings THEN the system SHALL display available AI methods with clear descriptions
2. WHEN Apple Intelligence is selected THEN the system SHALL use enhanced natural language processing beyond basic keyword matching
3. WHEN external services are selected THEN the system SHALL provide placeholder functionality with "Coming Soon" indicators
4. WHEN a method is unavailable THEN the system SHALL clearly indicate this and prevent selection
5. WHEN the user changes methods THEN existing summaries SHALL remain unchanged until regenerated

### Requirement 5

**User Story:** As a user, I want the summarization to handle different types of content appropriately, so that meeting notes, personal journals, and other content types are processed with relevant context.

#### Acceptance Criteria

1. WHEN the content appears to be a meeting or conversation THEN the system SHALL identify key decisions, action items, and participants
2. WHEN the content is personal journaling THEN the system SHALL focus on emotions, experiences, and personal insights
3. WHEN the content contains technical or professional information THEN the system SHALL preserve important terminology and concepts
4. WHEN the content type cannot be determined THEN the system SHALL apply general summarization techniques
5. WHEN the content is very short (under 100 words) THEN the system SHALL provide a brief summary or indicate insufficient content

### Requirement 6

**User Story:** As a user, I want to regenerate summaries with different settings or methods, so that I can improve the quality if the initial summary doesn't meet my needs.

#### Acceptance Criteria

1. WHEN a summary already exists THEN the user SHALL be able to regenerate it with the current settings
2. WHEN regenerating a summary THEN the system SHALL replace the previous version completely
3. WHEN regeneration fails THEN the system SHALL preserve the existing summary and show an error message
4. WHEN the user changes AI methods THEN they SHALL be prompted to regenerate existing summaries to use the new method
5. WHEN regenerating THEN the system SHALL show progress indicators and allow cancellation

### Requirement 7

**User Story:** As a developer, I want the summarization system to be extensible and maintainable, so that new AI services and methods can be easily integrated in the future.

#### Acceptance Criteria

1. WHEN new AI services are added THEN they SHALL integrate through a common interface without affecting existing functionality
2. WHEN summarization logic is updated THEN it SHALL not break existing saved summaries
3. WHEN errors occur during summarization THEN they SHALL be logged appropriately and handled gracefully
4. WHEN the system processes large transcripts THEN it SHALL handle memory and performance constraints appropriately
5. WHEN multiple summarization requests are made THEN the system SHALL queue them appropriately to prevent resource conflicts