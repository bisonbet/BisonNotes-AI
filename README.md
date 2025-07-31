# Audio Journal - Advanced AI-Powered Audio Processing

**Audio Journal** is a sophisticated iOS application that transforms spoken words into actionable insights through advanced AI-powered audio processing, transcription, and intelligent summarization. Built with modern SwiftUI architecture and comprehensive performance optimization.

## 🎯 Overview

Audio Journal is your personal AI assistant for capturing, transcribing, and analyzing audio recordings. Whether you're in meetings, brainstorming sessions, or personal reflections, the app automatically extracts key information, identifies actionable tasks, and creates intelligent summaries with location context. The app features advanced background processing, performance optimization, and comprehensive error handling.

## ✨ Key Features

### 🎙️ **Advanced Audio Recording**
- **High-Quality Recording**: Multiple audio quality settings (64kbps to 256kbps)
- **Mixed Audio Support**: Record without interrupting system audio playback
- **Background Recording**: Continues recording even when app is minimized
- **Flexible Input Support**: Built-in microphone, Bluetooth headsets, USB audio devices
- **Location Tracking**: Automatic GPS location capture with each recording
- **Smart Duration Management**: Auto-stop at 2 hours with real-time duration display
- **File Import**: Import existing audio files with progress tracking
- **Enhanced Audio Session Management**: Robust audio interruption handling

### 🤖 **AI-Powered Intelligence**
- **Enhanced Apple Intelligence Engine**: Advanced natural language processing using Apple's NLTagger with semantic analysis
- **OpenAI Integration**: GPT-4o, GPT-4o Mini, and Whisper-1 models for transcription and summarization
- **Google AI Studio Integration**: Gemini 2.5 Flash and Flash Lite models for AI-powered summaries
- **Whisper Integration**: High-quality transcription using OpenAI's Whisper model via REST API
- **Ollama Integration**: Local AI processing with customizable models
- **AWS Transcribe**: Cloud-based transcription service for long audio files
- **Content Classification**: Automatically categorizes content (meetings, personal journal, technical, general)
- **Smart Summarization**: Context-aware summaries based on content type
- **Task Extraction**: Identifies and categorizes actionable items with priority levels
- **Reminder Detection**: Extracts time-sensitive reminders with urgency classification
- **Intelligent Recording Names**: AI-generated names based on content analysis

### 📝 **Intelligent Transcription**
- **Real-Time Speech Recognition**: Powered by Apple's Speech framework
- **OpenAI Transcription**: GPT-4o, GPT-4o Mini, and Whisper-1 models via API
- **Whisper REST API**: High-quality transcription using local Whisper server
- **AWS Transcribe**: Cloud-based transcription service for long audio files
- **Enhanced Large File Support**: Automatic chunking for files over 5 minutes
- **Background Processing**: Transcription and summarization in background
- **Progress Tracking**: Real-time progress updates for long transcriptions
- **Timeout Handling**: Configurable timeout settings to prevent hanging
- **Speaker Diarization**: Identifies different speakers in conversations
- **Editable Transcripts**: Full editing capabilities with speaker management
- **Time-Stamped Segments**: Precise timing for each transcript segment
- **File Size Validation**: Automatic fallback for oversized files

### 📊 **Enhanced Summary View**
- **Expandable Sections**: Organized content with collapsible metadata, summary, tasks, and reminders
- **Visual Priority Indicators**: Color-coded task priorities (red for urgent, orange for important, green for normal)
- **Urgency Classification**: Visual indicators for reminder urgency (immediate, today, this week, later)
- **Confidence Scoring**: Visual confidence indicators for AI-generated content
- **Metadata Display**: AI method, generation time, content type, word count, compression ratio
- **Quality Validation**: Automatic quality assessment and recovery mechanisms
- **Enhanced Summary Detail View**: Comprehensive display with location mapping

### 🗺️ **Location Intelligence**
- **GPS Integration**: Automatic location capture with each recording
- **Reverse Geocoding**: Converts coordinates to human-readable addresses
- **Location History**: View recording locations on interactive maps
- **Privacy-First**: Optional location tracking with user control
- **Location Detail View**: Enhanced location display with map integration

### ⚙️ **Advanced Settings & Customization**
- **Multiple AI Engines**: Choose between different AI processing methods
- **Audio Quality Control**: Adjust recording quality based on needs
- **Speaker Diarization Options**: Basic pause detection and advanced methods
- **Batch Processing**: Regenerate all summaries with updated AI engines
- **Comprehensive Settings**: Fine-tune every aspect of the app
- **Engine Monitoring**: Automatic availability checking and recovery
- **Performance Optimization**: Battery and memory-aware processing

### 🔧 **Performance & Background Processing**
- **Background Processing Manager**: Comprehensive job queuing and management
- **Performance Optimizer**: Battery and memory-aware processing
- **Streaming File Processing**: Memory-efficient handling of large files
- **Adaptive Processing**: Dynamic optimization based on system resources
- **Battery Monitoring**: Real-time battery state tracking and optimization
- **Memory Management**: Intelligent cache management and cleanup
- **Error Recovery System**: Comprehensive error handling and recovery strategies

### 🛠️ **Enhanced File Management**
- **Selective File Deletion**: Confirmation dialogs and complete cleanup
- **File Relationship Tracking**: Maintains data integrity across deletions
- **Orphaned File Detection**: Identifies and manages orphaned files
- **iCloud Storage Manager**: CloudKit synchronization with conflict resolution
- **Enhanced File Manager**: Comprehensive file operations with error handling

## 🔧 AI Integration Setup

### **OpenAI Integration**

Audio Journal supports advanced AI processing using OpenAI's latest models for both transcription and summarization.

#### **Transcription Setup**
1. **Get OpenAI API Key**: Visit [platform.openai.com](https://platform.openai.com) to obtain an API key
2. **Configure in App**: Go to Settings → Transcription Settings → OpenAI
3. **Select Model**: Choose between GPT-4o Transcribe, GPT-4o Mini Transcribe, or Whisper-1
4. **Test Connection**: Use the test button to verify your configuration

#### **Summarization Setup**
1. **Configure API Key**: Go to Settings → AI Settings → OpenAI
2. **Select Model**: Choose from GPT-4o, GPT-4o Mini, or GPT-4o Nano
3. **Adjust Settings**: Configure temperature, max tokens, and timeout
4. **Test Connection**: Verify your setup with the test button

#### **Supported Models**
- **GPT-4o Transcribe**: Most robust transcription with GPT-4o model
- **GPT-4o Mini Transcribe**: Fastest and most economical transcription
- **Whisper-1**: Legacy high-quality transcription
- **GPT-4o**: Most powerful summarization with advanced reasoning
- **GPT-4o Mini**: Balanced performance and cost
- **GPT-4o Nano**: Fastest and most economical

### **Google AI Studio Integration**

Audio Journal supports Google's Gemini models for advanced AI processing.

#### **Setup Instructions**
1. **Get API Key**: Visit [Google AI Studio](https://aistudio.google.com) to obtain an API key
2. **Configure in App**: Go to Settings → AI Settings → Google AI Studio
3. **Select Model**: Choose from Gemini 2.5 Flash or 2.5 Flash Lite
4. **Test Connection**: Verify your configuration

#### **Available Models**
- **Gemini 2.5 Flash**: Fast and efficient for most tasks
- **Gemini 2.5 Flash Lite**: Lightweight version optimized for speed and cost efficiency

### **Whisper Integration**

Audio Journal supports high-quality transcription using OpenAI's Whisper model via a local REST API server.

#### **Setup Instructions**

1. **Install Whisper ASR Webservice**
   - Visit [Whisper ASR Webservice](https://github.com/ahmetoner/whisper-asr-webservice) for the official Docker-based implementation
   - This project provides a complete REST API wrapper around OpenAI's Whisper model

2. **Quick Start with Docker**
   ```bash
   # CPU Version
   docker run -d -p 9000:9000 \
     -e ASR_MODEL=base \
     -e ASR_ENGINE=openai_whisper \
     onerahmet/openai-whisper-asr-webservice:latest
   
   # GPU Version (if you have CUDA)
   docker run -d --gpus all -p 9000:9000 \
     -e ASR_MODEL=base \
     -e ASR_ENGINE=openai_whisper \
     onerahmet/openai-whisper-asr-webservice:latest-gpu
   ```

3. **Configure Audio Journal**
   - Open the app and go to Settings → Transcription Settings
   - Enable "Whisper (Local Server)"
   - Set the server URL (e.g., `http://192.168.1.100` or `http://localhost`)
   - Set the port (default: 9000)
   - Test the connection using the "Test Connection" button

4. **Available Models**
   - `tiny`: Fastest, lowest quality
   - `base`: Good balance of speed and quality
   - `small`: Better quality, slower processing
   - `medium`: High quality, slower processing
   - `large-v3`: Best quality, slowest processing

#### **Features**
- **Multiple Output Formats**: JSON, text, VTT, SRT, TSV
- **Word-level Timestamps**: Precise timing for each word
- **Voice Activity Detection**: Filter out non-speech audio
- **Speaker Diarization**: Identify different speakers (with WhisperX)
- **Broad Format Support**: FFmpeg integration for various audio/video formats

### **Ollama Integration**

Audio Journal supports local AI processing using Ollama, allowing you to run various AI models locally on your machine for enhanced privacy and customization.

#### **Setup Instructions**

1. **Install Ollama**
   - Visit [Ollama](https://www.ollama.com) to download and install Ollama
   - Follow the installation instructions for your operating system
   - Ollama supports macOS, Linux, and Windows

2. **Download AI Models**
   ```bash
   # Download a model (e.g., Llama 2)
   ollama pull llama2
   
   # Or try other models
   ollama pull mistral
   ollama pull codellama
   ollama pull llama2:13b
   ```

3. **Start Ollama Service**
   ```bash
   # Start the Ollama service
   ollama serve
   ```

4. **Configure Audio Journal**
   - Open the app and go to Settings → AI Settings
   - Enable "Ollama Integration"
   - Set the server URL (e.g., `http://localhost` or `http://192.168.1.100`)
   - Set the port (default: 11434)
   - Select your preferred model from the dropdown
   - Test the connection

#### **Available Models**
- **Llama 2**: General-purpose language model
- **Mistral**: Fast and efficient model
- **Code Llama**: Specialized for code generation
- **Vicuna**: Conversational AI model
- **And many more**: Check [Ollama Library](https://ollama.com/library) for the full list

#### **Features**
- **Local Processing**: All AI processing happens on your machine
- **Privacy-First**: No data sent to external servers
- **Customizable Models**: Choose from hundreds of available models
- **Offline Capability**: Works without internet connection
- **Resource Control**: Adjust model size based on your hardware

## 🏗️ Technical Architecture

### **Core Technologies**
- **SwiftUI**: Modern declarative UI framework
- **AVFoundation**: Professional audio recording and playback
- **Speech Framework**: Real-time speech recognition
- **Natural Language**: Advanced text processing and analysis
- **Core Location**: GPS and location services
- **Core Data**: Local data persistence
- **URLSession**: REST API communication for various AI services
- **Background Processing**: Comprehensive job management
- **Performance Optimization**: Battery and memory-aware processing

### **AI Processing Pipeline**
1. **Audio Capture** → High-quality recording with location metadata
2. **Speech Recognition** → Real-time transcription with speaker detection
3. **Content Analysis** → Natural language processing and classification
4. **Intelligent Extraction** → Task and reminder identification
5. **Summary Generation** → Context-aware summarization
6. **Metadata Enrichment** → Confidence scoring and quality metrics
7. **Background Processing** → Asynchronous job processing
8. **Performance Optimization** → Resource-aware processing

### **Data Models**
- **RecordingFile**: Audio file with metadata and location data
- **TranscriptData**: Structured transcript with speaker segments
- **SummaryData**: Enhanced summaries with tasks and reminders
- **EnhancedSummaryData**: Advanced summaries with AI metadata
- **LocationData**: GPS coordinates with reverse geocoding
- **ProcessingJob**: Background job management
- **AudioChunk**: Chunked audio processing for large files

## 🚀 Getting Started

### **Prerequisites**
- iOS 15.0 or later
- iPhone or iPad with microphone access
- Location services (optional but recommended)
- For OpenAI: API key from platform.openai.com
- For Google AI Studio: API key from aistudio.google.com
- For Whisper: Local server running Whisper ASR Webservice
- For Ollama: Local Ollama installation

### **Installation**
1. Clone the repository
2. Open `Audio Journal.xcodeproj` in Xcode
3. Select your target device or simulator
4. Build and run the application

### **First Use**
1. **Grant Permissions**: Allow microphone and location access when prompted
2. **Configure AI Services**: Set up OpenAI, Google AI Studio, Whisper, and/or Ollama integration
3. **Start Recording**: Tap the record button to begin capturing audio
4. **Generate Summary**: Use the Summaries tab to create AI-powered summaries
5. **View Transcripts**: Access detailed transcripts in the Transcripts tab
6. **Customize Settings**: Adjust audio quality, AI engines, and preferences
7. **Monitor Performance**: Use the performance monitoring features to optimize usage

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
- **Location Section**: Interactive map with recording location

### **Performance Monitoring**
- **Engine Performance View**: Real-time performance metrics
- **Background Processing View**: Job queue and processing status
- **Error Recovery View**: Comprehensive error handling and recovery
- **Debug View**: Advanced debugging and diagnostics

## 🔧 Configuration Options

### **Audio Settings**
- **Quality Levels**: Low (64kbps), Medium (128kbps), High (256kbps)
- **Input Selection**: Built-in mic, Bluetooth, USB audio devices
- **Location Tracking**: Enable/disable GPS capture
- **Mixed Audio**: Enable recording without interrupting system audio
- **Background Recording**: Enable continuous recording when app is minimized

### **AI Processing**
- **Engine Selection**: Enhanced Apple Intelligence, OpenAI, Google AI Studio, Ollama Integration
- **Speaker Diarization**: Basic pause detection, AWS Transcription, Whisper-based
- **Batch Regeneration**: Update all summaries with new AI engines
- **Engine Monitoring**: Automatic availability checking and recovery
- **Performance Optimization**: Battery and memory-aware processing

### **Background Processing**
- **Job Management**: View and manage background processing jobs
- **Queue Management**: Monitor job queue and processing status
- **Performance Monitoring**: Real-time performance metrics
- **Error Recovery**: Comprehensive error handling and recovery

### **OpenAI Settings**
- **API Configuration**: Secure API key input with validation
- **Model Selection**: Choose from available GPT models
- **Connection Testing**: Verify API connectivity
- **Usage Tracking**: Monitor token usage and costs

### **Google AI Studio Settings**
- **API Configuration**: Secure API key input with validation
- **Model Selection**: Choose from available Gemini models
- **Connection Testing**: Verify API connectivity
- **Feature Overview**: Display model capabilities and limits

### **Whisper Settings**
- **Server Configuration**: URL and port settings
- **Model Selection**: Choose from available Whisper models
- **Connection Testing**: Verify server connectivity
- **Output Format**: JSON, text, VTT, SRT, TSV

### **Ollama Settings**
- **Server Configuration**: URL and port settings
- **Model Selection**: Choose from available Ollama models
- **Connection Testing**: Verify Ollama service connectivity
- **Model Management**: Download and manage local models

### **Transcription Settings**
- **Enhanced Transcription**: Automatic handling of large audio files (60+ minutes)
- **Chunk Configuration**: Adjustable chunk size (1-10 minutes) and overlap settings
- **Timeout Management**: Configurable processing time limits (5-30 minutes)
- **Progress Display**: Real-time transcription progress tracking
- **Cancel Support**: Ability to cancel long-running transcriptions

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
- **Performance-First**: Optimized for smooth, responsive interactions

### **Performance**
- **Efficient Processing**: Optimized AI processing with parallel execution
- **Memory Management**: Smart caching and cleanup of audio resources
- **Battery Optimization**: Efficient location and audio processing
- **Storage Management**: Automatic cleanup of temporary files
- **Background Processing**: Asynchronous job processing for better UX

## 🔒 Privacy & Security

### **Data Protection**
- **Local Processing**: All AI processing happens on-device or local servers
- **No Cloud Storage**: Audio files and transcripts stored locally
- **Optional Location**: GPS tracking can be disabled
- **Permission Control**: Granular control over microphone and location access
- **Background Processing**: Secure job management with data protection

### **Privacy Features**
- **Local Storage**: All data remains on your device
- **No Analytics**: No tracking or data collection
- **Secure Permissions**: Minimal required permissions
- **User Control**: Full control over data and settings
- **Whisper Privacy**: Process audio on your local server
- **Ollama Privacy**: Run AI models locally without external dependencies
- **API Key Security**: Secure storage of API keys with validation

## 🛠️ Development

### **Project Structure**
```
Audio Journal/
├── Audio_JournalApp.swift          # Main app entry point
├── ContentView.swift               # Main UI and tab structure
├── EnhancedSummaryDetailView.swift # Enhanced summary display
├── SummariesView.swift             # Summary management
├── EnhancedAppleIntelligenceEngine.swift # AI processing engine
├── OpenAISummarizationEngine.swift # OpenAI integration
├── GoogleAIStudioService.swift     # Google AI Studio integration
├── WhisperService.swift            # Whisper REST API integration
├── OllamaService.swift             # Ollama integration
├── OpenAITranscribeService.swift   # OpenAI transcription
├── AWSTranscribeService.swift      # AWS transcription
├── BackgroundProcessingManager.swift # Background job management
├── PerformanceOptimizer.swift      # Performance optimization
├── EnhancedAudioSessionManager.swift # Audio session management
├── AudioFileChunkingService.swift  # Large file processing
├── TaskExtractor.swift             # Task identification logic
├── ReminderExtractor.swift         # Reminder extraction
├── LocationManager.swift           # GPS and location services
├── SummaryManager.swift            # Summary management
├── EnhancedTranscriptionManager.swift # Transcription management
├── EnhancedFileManager.swift       # File management
├── iCloudStorageManager.swift      # iCloud integration
├── ErrorHandlingSystem.swift       # Error handling
├── EnhancedErrorRecoverySystem.swift # Error recovery
├── EnhancedLoggingSystem.swift     # Logging system
├── Models/
│   ├── AudioModels.swift           # Core data models
│   ├── SummarizationEngine.swift   # AI engine protocols
│   ├── EnhancedSummaryData.swift   # Enhanced summary models
│   ├── AudioChunkingModels.swift  # Chunking models
│   ├── EnginePerformanceData.swift # Performance data
│   └── RecordingNameGenerator.swift # Name generation
├── ViewModels/
│   └── AudioRecorderViewModel.swift # Recording logic
├── Views/
│   ├── RecordingsView.swift        # Main recording interface
│   ├── RecordingsListView.swift    # Recording list with deletion
│   ├── TranscriptViews.swift       # Transcript functionality
│   ├── SettingsView.swift          # Settings management
│   ├── AISettingsView.swift        # AI engine configuration
│   ├── EnginePerformanceView.swift # Performance monitoring
│   ├── BackgroundProcessingView.swift # Background processing
│   ├── EnhancedErrorRecoveryView.swift # Error recovery
│   ├── EnhancedDebugView.swift     # Debug interface
│   └── EnhancedDeleteDialog.swift  # Deletion confirmation
└── Assets/                         # App icons and resources
```

### **Key Components**
- **AudioRecorderViewModel**: Manages recording, playback, and audio settings
- **SummaryManager**: Handles summary generation and storage
- **TranscriptManager**: Manages transcript creation and editing
- **LocationManager**: Handles GPS and geocoding services
- **BackgroundProcessingManager**: Manages background job processing
- **PerformanceOptimizer**: Optimizes battery and memory usage
- **EnhancedAudioSessionManager**: Manages audio session configuration
- **AudioFileChunkingService**: Handles large file processing
- **OpenAISummarizationService**: OpenAI API communication
- **GoogleAIStudioService**: Google AI Studio API communication
- **WhisperService**: REST API communication with Whisper server
- **OllamaService**: Local AI model communication
- **AWSTranscribeService**: AWS Transcribe API communication

## 🔮 Recent Enhancements

### **Performance Optimization (Task 11)**
- **Streaming File Processing**: Memory-efficient handling of large files
- **Battery Monitoring**: Real-time battery state tracking and optimization
- **Adaptive Processing**: Dynamic optimization based on system resources
- **Memory Management**: Intelligent cache management and cleanup
- **Background Processing**: Asynchronous job processing for better UX

### **Background Processing System**
- **Job Management**: Comprehensive job queuing and management
- **Progress Tracking**: Real-time progress updates for long operations
- **Error Recovery**: Robust error handling and recovery strategies
- **Performance Monitoring**: Real-time performance metrics and analytics

### **Enhanced File Management**
- **Selective Deletion**: Confirmation dialogs and complete cleanup
- **File Relationship Tracking**: Maintains data integrity across deletions
- **Orphaned File Detection**: Identifies and manages orphaned files
- **iCloud Integration**: CloudKit synchronization with conflict resolution

### **Mixed Audio Recording**
- **Background Audio**: Record without interrupting system audio playback
- **Audio Session Management**: Robust audio interruption handling
- **Enhanced Recording**: Improved audio quality and reliability

### **Large File Processing**
- **Intelligent Chunking**: Automatic chunking for files over 5 minutes
- **Streaming Processing**: Memory-efficient processing of large files
- **Progress Tracking**: Real-time progress updates for long operations
- **Error Recovery**: Robust error handling for large file operations

## 🔮 Future Enhancements

### **Planned Features**
- **AWS Bedrock Integration**: Advanced AI using AWS Bedrock foundation models
- **Enhanced Diarization**: Whisper-based speaker identification
- **Export Options**: PDF, text, and calendar integration
- **Collaboration**: Shared recordings and summaries
- **Voice Commands**: Hands-free operation
- **Cloud Integration**: Optional cloud backup and sync

### **AI Improvements**
- **Multi-language Support**: International language processing
- **Emotion Detection**: Sentiment analysis and mood tracking
- **Topic Clustering**: Automatic topic organization
- **Smart Suggestions**: AI-powered recommendations
- **Custom Models**: Support for fine-tuned models

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

## 🔗 External Dependencies

### **OpenAI**
- **Website**: [platform.openai.com](https://platform.openai.com)
- **Documentation**: [platform.openai.com/docs](https://platform.openai.com/docs)
- **API Reference**: [platform.openai.com/docs/api-reference](https://platform.openai.com/docs/api-reference)

### **Google AI Studio**
- **Website**: [aistudio.google.com](https://aistudio.google.com)
- **Documentation**: [ai.google.dev](https://ai.google.dev)
- **API Reference**: [ai.google.dev/api](https://ai.google.dev/api)

### **Whisper ASR Webservice**
- **Project**: [ahmetoner/whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice)
- **Documentation**: [ahmetoner.github.io/whisper-asr-webservice](https://ahmetoner.github.io/whisper-asr-webservice)
- **License**: MIT License
- **Features**: Multiple ASR engines, GPU support, FFmpeg integration

### **Ollama**
- **Website**: [www.ollama.com](https://www.ollama.com)
- **Documentation**: [ollama.com/docs](https://ollama.com/docs)
- **License**: MIT License
- **Features**: Local AI models, privacy-first, cross-platform support

### **AWS Transcribe**
- **Website**: [aws.amazon.com/transcribe](https://aws.amazon.com/transcribe)
- **Documentation**: [docs.aws.amazon.com/transcribe](https://docs.aws.amazon.com/transcribe)
- **Features**: Real-time transcription, speaker diarization, custom vocabularies

---

**Audio Journal** - Transform your spoken words into actionable intelligence with advanced AI processing and performance optimization. 🎯✨
