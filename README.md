# BisonNotes AI - Intelligent Audio Journal

**BisonNotes AI** is a sophisticated iOS application that transforms spoken words into actionable insights through advanced AI-powered audio processing, transcription, and intelligent summarization.

## 🎯 Overview

BisonNotes AI is your personal AI assistant for capturing, transcribing, and analyzing audio recordings. Whether you're in meetings, brainstorming sessions, or personal reflections, the app automatically extracts key information, identifies actionable tasks, and creates intelligent summaries with location context.

## ✨ Key Features

### 🎙️ **Advanced Audio Recording**
- **High-Quality Recording**: Multiple audio quality settings (64kbps to 256kbps)
- **Flexible Input Support**: Built-in microphone, Bluetooth headsets, USB audio devices
- **Location Tracking**: Automatic GPS location capture with each recording
- **Smart Duration Management**: Auto-stop at 2 hours with real-time duration display
- **Background Processing**: Continues recording even when app is minimized

### 🤖 **AI-Powered Intelligence**
- **Enhanced Apple Intelligence Engine**: Advanced natural language processing
- **Content Classification**: Automatically categorizes content (meetings, personal journal, technical, general)
- **Smart Summarization**: Context-aware summaries based on content type
- **Task Extraction**: Identifies and categorizes actionable items with priority levels
- **Reminder Detection**: Extracts time-sensitive reminders with urgency classification

### 📝 **Intelligent Transcription**
- **Real-Time Speech Recognition**: Powered by Apple's Speech framework
- **Speaker Diarization**: Identifies different speakers in conversations
- **Editable Transcripts**: Full editing capabilities with speaker management
- **Time-Stamped Segments**: Precise timing for each transcript segment

### 📊 **Enhanced Summary View**
- **Expandable Sections**: Organized content with collapsible metadata, summary, tasks, and reminders
- **Visual Priority Indicators**: Color-coded task priorities (red for urgent, orange for important, green for normal)
- **Urgency Classification**: Visual indicators for reminder urgency (immediate, today, this week, later)
- **Confidence Scoring**: Visual confidence indicators for AI-generated content
- **Metadata Display**: AI method, generation time, content type, word count, compression ratio

### 🗺️ **Location Intelligence**
- **GPS Integration**: Automatic location capture with each recording
- **Reverse Geocoding**: Converts coordinates to human-readable addresses
- **Location History**: View recording locations on interactive maps
- **Privacy-First**: Optional location tracking with user control

### ⚙️ **Advanced Settings & Customization**
- **Multiple AI Engines**: Choose between different AI processing methods
- **Audio Quality Control**: Adjust recording quality based on needs
- **Speaker Diarization Options**: Basic pause detection and advanced methods
- **Batch Processing**: Regenerate all summaries with updated AI engines
- **Comprehensive Settings**: Fine-tune every aspect of the app

## 🏗️ Technical Architecture

### **Core Technologies**
- **SwiftUI**: Modern declarative UI framework
- **AVFoundation**: Professional audio recording and playback
- **Speech Framework**: Real-time speech recognition
- **Natural Language**: Advanced text processing and analysis
- **Core Location**: GPS and location services
- **Core Data**: Local data persistence

### **AI Processing Pipeline**
1. **Audio Capture** → High-quality recording with location metadata
2. **Speech Recognition** → Real-time transcription with speaker detection
3. **Content Analysis** → Natural language processing and classification
4. **Intelligent Extraction** → Task and reminder identification
5. **Summary Generation** → Context-aware summarization
6. **Metadata Enrichment** → Confidence scoring and quality metrics

### **Data Models**
- **RecordingFile**: Audio file with metadata and location data
- **TranscriptData**: Structured transcript with speaker segments
- **SummaryData**: Enhanced summaries with tasks and reminders
- **EnhancedSummaryData**: Advanced summaries with AI metadata
- **LocationData**: GPS coordinates with reverse geocoding

## 🚀 Getting Started

### **Prerequisites**
- iOS 15.0 or later
- iPhone or iPad with microphone access
- Location services (optional but recommended)

### **Installation**
1. Clone the repository
2. Open `Audio Journal.xcodeproj` in Xcode
3. Select your target device or simulator
4. Build and run the application

### **First Use**
1. **Grant Permissions**: Allow microphone and location access when prompted
2. **Start Recording**: Tap the record button to begin capturing audio
3. **Generate Summary**: Use the Summaries tab to create AI-powered summaries
4. **View Transcripts**: Access detailed transcripts in the Transcripts tab
5. **Customize Settings**: Adjust audio quality, AI engines, and preferences

## 📱 User Interface

### **Main Tabs**
- **Record**: Primary recording interface with real-time feedback
- **Summaries**: AI-generated summaries with expandable sections
- **Transcripts**: Detailed transcripts with editing capabilities
- **Settings**: Comprehensive configuration options

### **Enhanced Summary View**
- **Metadata Section**: AI method, generation time, content statistics
- **Summary Section**: Context-aware content summaries
- **Tasks Section**: Categorized tasks with priority indicators
- **Reminders Section**: Time-sensitive reminders with urgency levels

## 🔧 Configuration Options

### **Audio Settings**
- **Quality Levels**: Low (64kbps), Medium (128kbps), High (256kbps)
- **Input Selection**: Built-in mic, Bluetooth, USB audio devices
- **Location Tracking**: Enable/disable GPS capture

### **AI Processing**
- **Engine Selection**: Enhanced Apple Intelligence (current), Local Server, AWS Bedrock (coming soon)
- **Speaker Diarization**: Basic pause detection, AWS Transcription, Whisper-based (coming soon)
- **Batch Regeneration**: Update all summaries with new AI engines

### **Content Analysis**
- **Task Categories**: Call, Email, Meeting, Purchase, Research, Travel, Health, General
- **Priority Levels**: High, Medium, Low with visual indicators
- **Reminder Urgency**: Immediate, Today, This Week, Later

## 🎨 Design Philosophy

### **User Experience**
- **Intuitive Interface**: Clean, modern design with clear visual hierarchy
- **Accessibility**: Support for VoiceOver and other accessibility features
- **Dark Mode**: Optimized for both light and dark appearances
- **Responsive Design**: Adapts to different screen sizes and orientations

### **Performance**
- **Efficient Processing**: Optimized AI processing with parallel execution
- **Memory Management**: Smart caching and cleanup of audio resources
- **Battery Optimization**: Efficient location and audio processing
- **Storage Management**: Automatic cleanup of temporary files

## 🔒 Privacy & Security

### **Data Protection**
- **Local Processing**: All AI processing happens on-device
- **No Cloud Storage**: Audio files and transcripts stored locally
- **Optional Location**: GPS tracking can be disabled
- **Permission Control**: Granular control over microphone and location access

### **Privacy Features**
- **Local Storage**: All data remains on your device
- **No Analytics**: No tracking or data collection
- **Secure Permissions**: Minimal required permissions
- **User Control**: Full control over data and settings

## 🛠️ Development

### **Project Structure**
```
Audio Journal/
├── Audio_JournalApp.swift          # Main app entry point
├── ContentView.swift               # Main UI and recording logic
├── SummaryDetailView.swift         # Enhanced summary display
├── SummariesView.swift             # Summary management
├── EnhancedAppleIntelligenceEngine.swift # AI processing engine
├── TaskExtractor.swift             # Task identification logic
├── ReminderExtractor.swift         # Reminder extraction
├── LocationManager.swift           # GPS and location services
├── SummaryData.swift               # Data models and persistence
└── Assets/                         # App icons and resources
```

### **Key Components**
- **AudioRecorderViewModel**: Manages recording, playback, and audio settings
- **SummaryManager**: Handles summary generation and storage
- **TranscriptManager**: Manages transcript creation and editing
- **LocationManager**: Handles GPS and geocoding services

## 🔮 Future Enhancements

### **Planned Features**
- **Cloud Integration**: Optional cloud backup and sync
- **Advanced AI Engines**: AWS Bedrock and local Ollama integration
- **Enhanced Diarization**: Whisper-based speaker identification
- **Export Options**: PDF, text, and calendar integration
- **Collaboration**: Shared recordings and summaries
- **Voice Commands**: Hands-free operation

### **AI Improvements**
- **Multi-language Support**: International language processing
- **Emotion Detection**: Sentiment analysis and mood tracking
- **Topic Clustering**: Automatic topic organization
- **Smart Suggestions**: AI-powered recommendations

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

We welcome contributions! Please see our contributing guidelines for more information.

### **Development Setup**
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## 📞 Support

For support, questions, or feature requests:
- Create an issue in the GitHub repository
- Check the documentation for common questions
- Review the settings for configuration help

---

**BisonNotes AI** - Transform your spoken words into actionable intelligence. 🎯✨
