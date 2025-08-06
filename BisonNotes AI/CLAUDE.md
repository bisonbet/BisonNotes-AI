# Claude Development Instructions

## Build Configuration

- Always use iPhone 16 as the build target for iOS Simulator builds
- Use platform=iOS Simulator,name=iPhone 16,OS=latest for xcodebuild commands
- Never ask to use iPhone 15 - always default to iPhone 16
- **IMPORTANT**: Always ask the user for permission before running any build commands (xcodebuild) to save tokens and LLM work. Let the user decide when to build.

## Project Structure

This is a SwiftUI iOS app for audio transcription and AI-powered summarization with the following key components:

- Audio recording and transcription
- Multiple AI engine support (OpenAI, AWS Bedrock, Ollama, Google AI Studio, Apple Intelligence)
- Enhanced summary data with tasks, reminders, and titles extraction
- iCloud sync capabilities
- Performance monitoring and optimization

## Development Guidelines

- Follow existing code patterns and conventions
- Use proper error handling with the ErrorHandlingSystem
- Maintain compatibility with existing data structures
- Test all changes thoroughly before completion