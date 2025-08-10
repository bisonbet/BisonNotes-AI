# Audio Journal - Advanced AI-Powered Audio Processing

**Audio Journal** is a sophisticated iOS application that transforms spoken words into actionable insights through advanced AI-powered audio processing, transcription, and intelligent summarization. Built with modern SwiftUI architecture and comprehensive performance optimization.

## 🎯 Overview

Audio Journal is your personal AI assistant for capturing, transcribing, and analyzing audio recordings. **All data is now managed exclusively via Core Data**—the legacy registry and file-based storage have been fully replaced. On first launch, the app will automatically migrate any legacy data into Core Data, ensuring seamless upgrades for existing users. The app features advanced background processing, performance optimization, comprehensive error handling, and a unified data model.

## 🆕 Recent Updates

### **Enhanced Location Search & Performance (Latest)**
- **Smart Location Search**: Intelligent 3-tier fallback system for failed location searches
- **University Database**: Built-in mapping for major universities (University of Oklahoma → Norman, Oklahoma)
- **Search Retry Logic**: Automatic retry with different search strategies for better results
- **Performance Improvements**: Fixed SF Symbol issues causing UI hangs and optimized background processing
- **Better Error Handling**: User-friendly error messages with actionable suggestions
- **UI Optimization**: Background location processing prevents typing delays and UI blocking

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
- **Automatic Registry Integration**: New recordings are automatically added to the unified data registry

### 🗄️ **Unified Data Management (Core Data Only)**
- **Centralized Data Management**: All recordings, transcripts, summaries, and processing jobs are managed via Core Data
- **Automatic Recording Registration**: New recordings are automatically added to Core Data with full metadata
- **Data Migration**: On first launch, legacy file-based data is migrated into Core Data using the new migration system
- **Data Integrity**: Maintains relationships between recordings, transcripts, and summaries
- **Debug & Migration Tools**: Built-in views for migration, debugging, and clearing the database
- **No Legacy Registry**: The old registry and file-based storage are fully removed

### 🤖 **AI-Powered Intelligence**
- **Enhanced Apple Intelligence Engine**: Advanced natural language processing using Apple's NLTagger with semantic analysis
- **OpenAI Integration**: GPT-4o, GPT-4o Mini, and Whisper-1 models for transcription and summarization
- **Google AI Studio Integration**: Gemini 2.5 Flash and Flash Lite models for AI-powered summaries
- **Whisper Integration**: High-quality transcription using OpenAI's Whisper model via REST API
- **Wyoming Protocol**: Streaming transcription using Whisper models via WebSocket and TCP
- **Ollama Integration**: Local AI processing with customizable models
- **AWS Bedrock Integration**: Cloud-based AI using AWS Bedrock foundation models
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
- **Wyoming Protocol**: Streaming transcription using Whisper models via WebSocket and TCP
- **AWS Transcribe**: Cloud-based transcription service for long audio files
- **Enhanced Large File Support**: Automatic chunking for files over 5 minutes
- **Background Processing**: Transcription and summarization in background
- **Progress Tracking**: Real-time progress updates for long transcriptions
- **Timeout Handling**: Configurable timeout settings to prevent hanging
- **Editable Transcripts**: Full editing capabilities with text management
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
- **Location Maps**: Interactive maps showing recording locations with Apple-style design

### 🗺️ **Location Intelligence**
- **GPS Integration**: Automatic location capture with each recording
- **Reverse Geocoding**: Converts coordinates to human-readable addresses
- **Smart Location Search**: Advanced search with fallback strategies for landmarks and universities
- **University Mapping**: Built-in database of major universities and their locations
- **Search Fallbacks**: Intelligent retry logic for failed location searches
- **Location History**: View recording locations on interactive maps
- **Privacy-First**: Optional location tracking with user control
- **Location Detail View**: Enhanced location display with map integration
- **Interactive Maps**: Full-screen map views with navigation integration
- **Performance Optimized**: Background location processing to prevent UI blocking

### ⚙️ **Advanced Settings & Customization**
- **Multiple AI Engines**: Choose between different AI processing methods
- **Audio Quality Control**: Adjust recording quality based on needs
- **Batch Processing**: Regenerate all summaries with updated AI engines
- **Comprehensive Settings**: Fine-tune every aspect of the app
- **Engine Monitoring**: Automatic availability checking and recovery
- **Performance Optimization**: Battery and memory-aware processing
- **Registry Management**: Debug tools for managing the unified data registry

### 🔧 **Performance & Background Processing**
- **Background Processing Manager**: Comprehensive job queuing and management
- **Performance Optimizer**: Battery and memory-aware processing
- **Streaming File Processing**: Memory-efficient handling of large files
- **Adaptive Processing**: Dynamic optimization based on system resources
- **Battery Monitoring**: Real-time battery state tracking and optimization
- **Memory Management**: Intelligent cache management and cleanup
- **Error Recovery System**: Comprehensive error handling and recovery strategies
- **Stale Job Detection**: Automatic cleanup of abandoned processing jobs
- **Timeout Management**: Configurable timeouts for long-running operations
- **UI Performance Fixes**: Fixed SF Symbol issues and background threading for smooth interactions

### 🛠️ **Enhanced File Management**
- **Selective File Deletion**: Confirmation dialogs and complete cleanup
- **File Relationship Tracking**: Maintains data integrity across deletions
- **Orphaned File Detection**: Identifies and manages orphaned files
- **iCloud Storage Manager**: CloudKit synchronization with conflict resolution
- **Enhanced File Manager**: Comprehensive file operations with error handling
- **Registry Integration**: All file operations are coordinated through Core Data

### 🧩 **Data Migration & Debugging**
- **DataMigrationView**: Run and monitor migration from legacy storage to Core Data
- **Clear & Debug Tools**: Clear the database or inspect its contents from the UI
- **Data Integrity Checks**: Comprehensive validation of Core Data relationships
- **Repair Tools**: Automatic fixing of data inconsistencies and orphaned entries

### 🧑‍💻 **Audio Playback**
- **AudioPlayerView**: New SwiftUI view for playing back audio recordings with metadata and controls

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
- **Broad Format Support**: FFmpeg integration for various audio/video formats

### **Wyoming Protocol Integration**

Audio Journal supports the Wyoming protocol for streaming transcription using Whisper models. This provides a modern, efficient alternative to REST API-based transcription.

#### **Setup Instructions**

1. **Install Wyoming Server**
   - Visit [Wyoming](https://github.com/rhasspy/wyoming) for the official implementation
   - Or use a Wyoming-compatible Whisper server like [whisper.cpp](https://github.com/ggerganov/whisper.cpp)

2. **Quick Start with Docker**
   ```bash
   # Run a Wyoming-compatible Whisper server
   docker run -d -p 10300:10300 \
     --name wyoming-whisper \
     rhasspy/wyoming-whisper:latest
   ```

3. **Configure Audio Journal**
   - Open the app and go to Settings → Transcription Settings
   - Select "Whisper (Wyoming Protocol)" as the transcription engine
   - Set the server URL (e.g., `http://192.168.1.100` or `http://localhost`)
   - Set the port (default: 10300)
   - Test the connection using the "Test Connection" button

#### **Features**
- **Streaming Protocol**: Real-time transcription with minimal latency
- **WebSocket & TCP Support**: Both connection types supported
- **Multiple Models**: Support for various Whisper model sizes
- **Local Processing**: Run on your own hardware for privacy
- **Cross-Platform**: Works on macOS, Linux, and Windows
- **Background Processing**: Continues transcription when app is minimized

#### **Available Models**
- `tiny`: Fastest, lowest quality
- `base`: Good balance of speed and quality
- `small`: Better quality, slower processing
- `medium`: High quality, slower processing
- `large-v3`: Best quality, slowest processing

### **AWS Bedrock Integration**

Audio Journal supports advanced AI processing using AWS Bedrock foundation models for both transcription and summarization.

#### **Setup Instructions**

1. **Get AWS Credentials**: Visit [AWS Console](https://console.aws.amazon.com) to set up your AWS account
2. **Configure in App**: Go to Settings → AI Settings → AWS Bedrock
3. **Select Model**: Choose from available foundation models
4. **Test Connection**: Use the test button to verify your configuration

#### **Supported Models**
- **Claude 3.5 Sonnet**: Advanced reasoning and analysis
- **Claude 3.5 Haiku**: Fast and efficient processing
- **Llama 2**: Open-source language model
- **And many more**: Check AWS Bedrock console for available models

#### **Features**
- **Cloud-Based Processing**: Leverage AWS infrastructure for powerful AI processing
- **Multiple Models**: Access to various foundation models
- **Scalable**: Handles large files and complex processing tasks
- **Secure**: Enterprise-grade security and compliance

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

### **AWS Transcribe Integration**

Audio Journal supports cloud-based transcription using AWS Transcribe service for handling large audio files.

#### **Setup Instructions**

1. **Get AWS Credentials**: Visit [AWS Console](https://console.aws.amazon.com) to set up your AWS account
2. **Configure in App**: Go to Settings → Transcription Settings → AWS Transcribe
3. **Select Region**: Choose appropriate AWS region
4. **Test Connection**: Use the test button to verify your configuration

#### **Features**
- **Cloud-Based Processing**: Leverage AWS infrastructure for large files
- **Multiple Languages**: Support for various languages and accents
- **Custom Vocabularies**: Train models on domain-specific terminology
- **Real-Time Processing**: Stream audio for immediate transcription
- **Batch Processing**: Handle files up to 4GB in size

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
- **Unified Registry System**: Centralized data management for recordings, transcripts, and summaries

### **AI Processing Pipeline**
1. **Audio Capture** → High-quality recording with location metadata
2. **Registry Integration** → Automatic recording registration in unified data system
3. **Speech Recognition** → Real-time transcription with text processing
4. **Content Analysis** → Natural language processing and classification
5. **Intelligent Extraction** → Task and reminder identification
6. **Summary Generation** → Context-aware summarization
7. **Metadata Enrichment** → Confidence scoring and quality metrics
8. **Background Processing** → Asynchronous job processing
9. **Performance Optimization** → Resource-aware processing

### **Data Models**
- **RegistryRecordingEntry**: Central recording data with metadata and processing status
- **TranscriptData**: Structured transcript with text segments
- **SummaryData**: Enhanced summaries with tasks and reminders
- **EnhancedSummaryData**: Advanced summaries with AI metadata
- **LocationData**: GPS coordinates with reverse geocoding
- **ProcessingJob**: Background job management
- **AudioChunk**: Chunked audio processing for large files
- **AppDataCoordinator**: Unified data coordination and registry management

## 🚀 Getting Started

### **Prerequisites**
- iOS 15.0 or later
- iPhone or iPad with microphone access
- Location services (optional but recommended)
- For OpenAI: API key from platform.openai.com
- For Google AI Studio: API key from aistudio.google.com
- For Whisper: Local server running Whisper ASR Webservice
- For Wyoming: Local Wyoming-compatible server
- For Ollama: Local Ollama installation
- For AWS Bedrock: AWS account with Bedrock access

### **Initialization**
1. **First Launch**: On your first launch, the app will automatically scan for any existing audio, transcript, and summary files in your app's document directory. It will then migrate this data into Core Data, ensuring a seamless transition.
2. **Subsequent Launches**: On subsequent launches, the app will check for new data in the document directory and migrate it.

### **Installation**
1. Clone the repository
2. Open `Audio Journal.xcodeproj` in Xcode
3. Select your target device or simulator
4. Build and run the application

### **First Use**
1. **Grant Permissions**: Allow microphone and location access when prompted
2. **Automatic Migration**: On first launch, the app will scan for legacy audio, transcript, and summary files and migrate them into Core Data. Progress is shown in the Data Migration view if needed.
3. **Configure AI Services**: Set up OpenAI, Google AI Studio, Whisper, and/or Ollama integration
4. **Start Recording**: Tap the record button to begin capturing audio
5. **Generate Summary**: Use the Summaries tab to create AI-powered summaries
6. **View Transcripts**: Access detailed transcripts in the Transcripts tab
7. **Customize Settings**: Adjust audio quality, AI engines, and preferences
8. **Monitor Performance**: Use the performance monitoring features to optimize usage
9. **Database Management**: Use the Data Migration view to debug, clear, or re-migrate data if needed

## 📱 User Interface

### **Main Tabs**
- **Record**: Primary recording interface with real-time feedback
- **Summaries**: AI-generated summaries with expandable sections
- **Transcripts**: Detailed transcripts with editing capabilities
- **Settings**: Comprehensive configuration options
- **Data Migration**: (Accessible from Settings) Run, debug, or clear the Core Data database

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
- **Registry Debug Tools**: Tools for managing the unified data registry

### **Audio Playback**
- **AudioPlayerView**: Play back any recording with full metadata and controls

## 🔧 Configuration Options

### **Audio Settings**
- **Quality Levels**: Low (64kbps), Medium (128kbps), High (256kbps)
- **Input Selection**: Built-in mic, Bluetooth, USB audio devices
- **Location Tracking**: Enable/disable GPS capture
- **Mixed Audio**: Enable recording without interrupting system audio
- **Background Recording**: Enable continuous recording when app is minimized

### **AI Processing**
- **Engine Selection**: Enhanced Apple Intelligence, OpenAI, Google AI Studio, AWS Bedrock, Ollama Integration
- **Batch Regeneration**: Update all summaries with new AI engines
- **Engine Monitoring**: Automatic availability checking and recovery
- **Performance Optimization**: Battery and memory-aware processing

### **Background Processing**
- **Job Management**: View and manage background processing jobs
- **Queue Management**: Monitor job queue and processing status
- **Performance Monitoring**: Real-time performance metrics
- **Error Recovery**: Comprehensive error handling and recovery
- **Stale Job Cleanup**: Automatic detection and cleanup of abandoned jobs

### **Registry Management**
- **Refresh Recordings**: Scan and add missing recordings from disk
- **Debug Tools**: Comprehensive debugging and recovery tools
- **Data Integrity**: Maintain relationships between recordings, transcripts, and summaries
- **Registry Coordination**: Seamless coordination between all data components

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

### **Wyoming Settings**
- **Server Configuration**: URL and port settings for Wyoming server
- **Model Selection**: Choose from available Whisper models
- **Connection Testing**: Verify Wyoming server connectivity
- **Streaming Options**: Configure real-time transcription settings
- **Connection Type**: WebSocket or TCP connection options

### **Ollama Settings**
- **Server Configuration**: URL and port settings
- **Model Selection**: Choose from available Ollama models
- **Connection Testing**: Verify Ollama service connectivity
- **Model Management**: Download and manage local models

### **AWS Bedrock Settings**
- **AWS Credentials**: Configure access keys or use AWS profiles
- **Model Selection**: Choose from available foundation models
- **Region Configuration**: Select appropriate AWS region
- **Connection Testing**: Verify AWS Bedrock connectivity
- **Usage Monitoring**: Track API usage and costs

### **AWS Transcribe Settings**
- **AWS Credentials**: Configure access keys or use AWS profiles
- **Region Configuration**: Select appropriate AWS region
- **Language Selection**: Choose from supported languages
- **Connection Testing**: Verify AWS Transcribe connectivity

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
- **Registry Optimization**: Efficient data management and coordination

## 🔒 Privacy & Security

### **Data Protection**
- **Local Processing**: All AI processing happens on-device or local servers
- **No Cloud Storage**: Audio files and transcripts stored locally
- **Optional Location**: GPS tracking can be disabled
- **Permission Control**: Granular control over microphone and location access
- **Background Processing**: Secure job management with data protection
- **Registry Privacy**: All registry data remains local and private

### **Privacy Features**
- **Local Storage**: All data remains on your device
- **No Analytics**: No tracking or data collection
- **Secure Permissions**: Minimal required permissions
- **User Control**: Full control over data and settings
- **Whisper Privacy**: Process audio on your local server
- **Ollama Privacy**: Run AI models locally without external dependencies
- **API Key Security**: Secure storage of API keys with validation

## 🛠️ Error Handling Improvements

- **ThumbnailErrorHandling**: Gracefully handles thumbnail generation errors during file operations, preventing interruptions
- **Robust Migration**: Migration process is resilient to missing/corrupt files and provides progress and error feedback
- **Comprehensive Logging**: All data operations and errors are logged for easier debugging
- **File Path Resolution**: Enhanced URL handling with proper decoding and fallback mechanisms
- **Markdown Rendering**: Improved text formatting with custom preprocessing for AI-generated content

## 🛠️ Development

### **Project Structure**
```
Audio Journal/
├── BisonNotesAIApp.swift          # Main app entry point
├── ContentView.swift               # Main UI and tab structure
├── Models/
│   ├── AppDataCoordinator.swift    # Unified data coordination (Core Data only)
│   ├── CoreDataManager.swift       # Core Data access layer
│   ├── DataMigrationManager.swift  # Handles migration from legacy storage
│   ├── RecordingWorkflowManager.swift # Orchestrates recording/transcription/summary workflow
│   ├── ... (other models)
├── Views/
│   ├── RecordingsView.swift        # Main recording interface
│   ├── AudioPlayerView.swift       # Audio playback UI
│   ├── DataMigrationView.swift     # Data migration and debug UI
│   ├── ... (other views)
├── ViewModels/
│   └── AudioRecorderViewModel.swift # Recording logic with Core Data integration
├── Wyoming/                        # Wyoming protocol implementation
│   ├── WyomingProtocol.swift       # Protocol message definitions
│   ├── WyomingTCPClient.swift      # TCP client implementation
│   ├── WyomingWebSocketClient.swift # WebSocket client implementation
│   └── WyomingWhisperClient.swift  # Whisper-specific client
├── ... (AI engines, managers, etc.)
```

### **Key Components**
- **CoreDataManager**: Central data access for all app data
- **DataMigrationManager**: Handles migration from legacy storage to Core Data
- **RecordingWorkflowManager**: Orchestrates the full workflow and ensures data integrity
- **AppDataCoordinator**: Unified interface for all data operations
- **AudioPlayerView**: Audio playback UI
- **DataMigrationView**: Migration and debug UI
- **WyomingWhisperClient**: Streaming transcription via Wyoming protocol

## 🔮 Recent Enhancements

### **Location Maps & File Path Resolution (Latest)**
- **Interactive Location Maps**: Enhanced summary views now display recording locations with Apple-style maps
- **File Path Resolution**: Fixed critical URL resolution issues preventing access to transcripts and summaries
- **Markdown Rendering**: Improved text formatting with custom preprocessing for AI-generated content
- **Data Integrity**: Enhanced Core Data relationship management and URL handling

### **Wyoming Protocol Integration**
- **Streaming Transcription**: Real-time transcription using Wyoming protocol via WebSocket and TCP
- **Background Processing**: Continues transcription when app is minimized
- **Multiple Connection Types**: Support for both WebSocket and TCP connections
- **Timeout Management**: Configurable timeouts for long-running transcriptions

### **Background Processing Improvements**
- **Stale Job Detection**: Automatic cleanup of abandoned processing jobs
- **Timeout Management**: Configurable timeouts for long-running operations
- **Enhanced Error Recovery**: Comprehensive error handling and recovery strategies
- **Performance Monitoring**: Real-time performance metrics and analytics

### **Core Data-Only Architecture**
- **All data is now managed via Core Data**—no legacy registry or file-based storage
- **Automatic migration** on first launch for existing users
- **New migration and debug tools** in the UI
- **AudioPlayerView** and **DataMigrationView** added
- **AWS Bedrock Integration**: Full support for AWS Bedrock foundation models

### **Performance Optimization**
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

### **Large File Processing**
- **Intelligent Chunking**: Automatic chunking for files over 5 minutes
- **Streaming Processing**: Memory-efficient processing of large files
- **Progress Tracking**: Real-time progress updates for long operations
- **Error Recovery**: Robust error handling for large file operations

## 🔮 Future Enhancements

### **Planned Features**

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

### **AWS Bedrock**
- **Website**: [aws.amazon.com/bedrock](https://aws.amazon.com/bedrock)
- **Documentation**: [docs.aws.amazon.com/bedrock](https://docs.aws.amazon.com/bedrock)
- **Features**: Foundation models, Claude, Llama 2, and other AI models

### **AWS Transcribe**
- **Website**: [aws.amazon.com/transcribe](https://aws.amazon.com/transcribe)
- **Documentation**: [docs.aws.amazon.com/transcribe](https://docs.aws.amazon.com/transcribe)
- **Features**: Real-time transcription, custom vocabularies

### **Wyoming Protocol**
- **Project**: [rhasspy/wyoming](https://github.com/rhasspy/wyoming)
- **Documentation**: [wyoming.rhasspy.org](https://wyoming.rhasspy.org)
- **License**: MIT License
- **Features**: Streaming protocol, WebSocket communication, real-time transcription

---

**Audio Journal** - Transform your spoken words into actionable intelligence with advanced AI processing, performance optimization, and unified data management. 🎯✨
