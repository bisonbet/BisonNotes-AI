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
- **Whisper Integration**: High-quality transcription using OpenAI's Whisper model via REST API
- **Ollama Integration**: Local AI processing with customizable models
- **Content Classification**: Automatically categorizes content (meetings, personal journal, technical, general)
- **Smart Summarization**: Context-aware summaries based on content type
- **Task Extraction**: Identifies and categorizes actionable items with priority levels
- **Reminder Detection**: Extracts time-sensitive reminders with urgency classification

### 📝 **Intelligent Transcription**
- **Real-Time Speech Recognition**: Powered by Apple's Speech framework
- **Whisper REST API**: High-quality transcription using local Whisper server
- **Enhanced Large File Support**: Automatic chunking for files over 5 minutes
- **Progress Tracking**: Real-time progress updates for long transcriptions
- **Timeout Handling**: Configurable timeout settings to prevent hanging
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

## 🔧 AI Integration Setup

### **Whisper Integration**

BisonNotes AI supports high-quality transcription using OpenAI's Whisper model via a local REST API server. This provides superior transcription quality compared to Apple's built-in speech recognition.

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

3. **Configure BisonNotes AI**
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

BisonNotes AI supports local AI processing using Ollama, allowing you to run various AI models locally on your machine for enhanced privacy and customization.

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

4. **Configure BisonNotes AI**
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
- **URLSession**: REST API communication for Whisper and Ollama

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
- For Whisper: Local server running Whisper ASR Webservice
- For Ollama: Local Ollama installation

### **Installation**
1. Clone the repository
2. Open `Audio Journal.xcodeproj` in Xcode
3. Select your target device or simulator
4. Build and run the application

### **First Use**
1. **Grant Permissions**: Allow microphone and location access when prompted
2. **Configure AI Services**: Set up Whisper and/or Ollama integration
3. **Start Recording**: Tap the record button to begin capturing audio
4. **Generate Summary**: Use the Summaries tab to create AI-powered summaries
5. **View Transcripts**: Access detailed transcripts in the Transcripts tab
6. **Customize Settings**: Adjust audio quality, AI engines, and preferences

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
- **Engine Selection**: Enhanced Apple Intelligence, Whisper (Local Server), Ollama Integration
- **Speaker Diarization**: Basic pause detection, AWS Transcription, Whisper-based (coming soon)
- **Batch Regeneration**: Update all summaries with new AI engines

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

### **Performance**
- **Efficient Processing**: Optimized AI processing with parallel execution
- **Memory Management**: Smart caching and cleanup of audio resources
- **Battery Optimization**: Efficient location and audio processing
- **Storage Management**: Automatic cleanup of temporary files

## 🔒 Privacy & Security

### **Data Protection**
- **Local Processing**: All AI processing happens on-device or local servers
- **No Cloud Storage**: Audio files and transcripts stored locally
- **Optional Location**: GPS tracking can be disabled
- **Permission Control**: Granular control over microphone and location access

### **Privacy Features**
- **Local Storage**: All data remains on your device
- **No Analytics**: No tracking or data collection
- **Secure Permissions**: Minimal required permissions
- **User Control**: Full control over data and settings
- **Whisper Privacy**: Process audio on your local server
- **Ollama Privacy**: Run AI models locally without external dependencies

## 🛠️ Development

### **Project Structure**
```
Audio Journal/
├── Audio_JournalApp.swift          # Main app entry point
├── ContentView.swift               # Main UI and recording logic
├── SummaryDetailView.swift         # Enhanced summary display
├── SummariesView.swift             # Summary management
├── EnhancedAppleIntelligenceEngine.swift # AI processing engine
├── WhisperService.swift            # Whisper REST API integration
├── OllamaService.swift             # Ollama integration
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
- **WhisperService**: REST API communication with Whisper server
- **OllamaService**: Local AI model communication

## 🔮 Future Enhancements

### **Planned Features**
- **Cloud Integration**: Optional cloud backup and sync
- **Advanced AI Engines**: AWS Bedrock and additional local AI integrations
- **Enhanced Diarization**: Whisper-based speaker identification
- **Export Options**: PDF, text, and calendar integration
- **Collaboration**: Shared recordings and summaries
- **Voice Commands**: Hands-free operation

### **AI Improvements**
- **Multi-language Support**: International language processing
- **Emotion Detection**: Sentiment analysis and mood tracking
- **Topic Clustering**: Automatic topic organization
- **Smart Suggestions**: AI-powered recommendations
- **Custom Models**: Support for fine-tuned Whisper and Ollama models

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

---

**BisonNotes AI** - Transform your spoken words into actionable intelligence. 🎯✨
