# Audio Journal - Complete User Guide

Welcome to Audio Journal! This comprehensive guide will walk you through every aspect of using the app, from basic recording to advanced AI configuration.

## 📱 Getting Started

### First Launch
1. **Install the App**: Download Audio Journal from the App Store
2. **Grant Permissions**: When prompted, allow:
   - **Microphone Access**: Required for recording audio
   - **Location Services**: Optional but recommended for location tracking
3. **Automatic Migration**: On first launch, the app will automatically scan for any existing audio files and migrate them into the database

### Basic Recording
1. **Start Recording**: Tap the large microphone button on the main screen
2. **Recording Status**: You'll see a red recording indicator and timer
3. **Stop Recording**: Tap the stop button to end recording
4. **Background Recording**: The app continues recording even when minimized

## 🎙️ Recording Features

### Audio Quality Settings
- **Low Quality (64kbps)**: Small file size, good for voice memos
- **Medium Quality (128kbps)**: Balanced quality and file size
- **High Quality (256kbps)**: Best audio quality, larger files

### Location Tracking
- **Automatic**: GPS location is captured with each recording
- **Manual**: Add or edit location later in summary view
- **Privacy**: Location tracking can be disabled in settings

### Import Existing Audio
1. Tap "Import Audio Files" on the main screen
2. Select audio files from your device
3. Files are automatically added to your recordings library

## 🤖 AI Engine Configuration

### Overview
Audio Journal supports multiple AI engines for transcription and summarization. Each has different capabilities and requirements.

### 1. Enhanced Apple Intelligence (Default)
**Type**: On-device processing  
**Cost**: Free  
**Privacy**: 100% local  
**Internet**: Not required  

**Setup**: No configuration needed - works out of the box

**Best for**: Privacy-conscious users, offline use, basic transcription and summarization

### 2. OpenAI Integration
**Type**: Cloud-based AI  
**Cost**: Pay-per-use (very affordable)  
**Privacy**: Data sent to OpenAI  
**Internet**: Required  

#### Setup Instructions:
1. **Get API Key**: Visit [platform.openai.com](https://platform.openai.com)
2. **Create Account**: Sign up for an OpenAI account
3. **Generate API Key**: Go to API Keys section and create a new key
4. **Configure in App**: 
   - Go to Settings → AI Settings → OpenAI
   - Enter your API key
   - Select your preferred model
   - Test the connection

#### Available Models:
- **GPT-4o**: Most powerful, best quality
- **GPT-4o Mini**: Fast and economical
- **GPT-4o Nano**: Fastest and most economical

#### Transcription Models:
- **GPT-4o Transcribe**: Best transcription quality
- **GPT-4o Mini Transcribe**: Fast transcription
- **Whisper-1**: Legacy high-quality transcription

### 3. Google AI Studio Integration
**Type**: Cloud-based AI  
**Cost**: Free tier available, then pay-per-use  
**Privacy**: Data sent to Google  
**Internet**: Required  

#### Setup Instructions:
1. **Get API Key**: Visit [aistudio.google.com](https://aistudio.google.com)
2. **Create Account**: Sign up for Google AI Studio
3. **Generate API Key**: Create a new API key
4. **Configure in App**:
   - Go to Settings → AI Settings → Google AI Studio
   - Enter your API key
   - Select model (Gemini 2.5 Flash or Flash Lite)
   - Test the connection

### 4. Whisper Integration (Local Server)
**Type**: Local AI processing  
**Cost**: Free (requires your own server)  
**Privacy**: 100% local  
**Internet**: Not required for processing  

#### Setup Instructions:
1. **Install Whisper Server**: 
   ```bash
   # Using Docker (recommended)
   docker run -d -p 9000:9000 \
     -e ASR_MODEL=base \
     -e ASR_ENGINE=openai_whisper \
     onerahmet/openai-whisper-asr-webservice:latest
   ```

2. **Configure in App**:
   - Go to Settings → Transcription Settings → Whisper
   - Set server URL (e.g., `http://localhost` or `http://192.168.1.100`)
   - Set port (default: 9000)
   - Select model size (tiny, base, small, medium, large-v3)
   - Test the connection

### 5. Wyoming Protocol Integration
**Type**: Local streaming transcription  
**Cost**: Free (requires your own server)  
**Privacy**: 100% local  
**Internet**: Not required for processing  

#### Setup Instructions:
1. **Install Wyoming Server**:
   ```bash
   # Using Docker
   docker run -d -p 10300:10300 \
     --name wyoming-whisper \
     rhasspy/wyoming-whisper:latest
   ```

2. **Configure in App**:
   - Go to Settings → Transcription Settings
   - Select "Whisper (Wyoming Protocol)"
   - Set server URL and port (default: 10300)
   - Test the connection

### 6. Ollama Integration
**Type**: Local AI processing  
**Cost**: Free  
**Privacy**: 100% local  
**Internet**: Not required for processing  

#### Setup Instructions:
1. **Install Ollama**: Visit [ollama.com](https://www.ollama.com)
2. **Download Models**:
   ```bash
   ollama pull llama2
   ollama pull mistral
   ```

3. **Configure in App**:
   - Go to Settings → AI Settings → Ollama
   - Set server URL (default: `http://localhost`)
   - Set port (default: 11434)
   - Select your preferred model
   - Test the connection

### 7. AWS Bedrock Integration
**Type**: Cloud-based AI  
**Cost**: Pay-per-use  
**Privacy**: Data sent to AWS  
**Internet**: Required  

#### Setup Instructions:
1. **AWS Account**: Create an AWS account
2. **Enable Bedrock**: Enable AWS Bedrock service
3. **Create IAM User**: Create user with Bedrock permissions
4. **Get Credentials**: Generate access keys
5. **Configure in App**:
   - Go to Settings → AI Settings → AWS Bedrock
   - Enter AWS credentials
   - Select region
   - Choose foundation model
   - Test the connection

### 8. AWS Transcribe Integration
**Type**: Cloud-based transcription  
**Cost**: Pay-per-use  
**Privacy**: Data sent to AWS  
**Internet**: Required  

#### Setup Instructions:
1. **AWS Account**: Create an AWS account
2. **Enable Transcribe**: Enable AWS Transcribe service
3. **Create IAM User**: Create user with Transcribe permissions
4. **Get Credentials**: Generate access keys
5. **Configure in App**:
   - Go to Settings → Transcription Settings → AWS Transcribe
   - Enter AWS credentials
   - Select region
   - Choose language
   - Test the connection

## 📝 Transcription Configuration

### Engine Selection
1. Go to Settings → Transcription Settings
2. Select your preferred transcription engine
3. Configure the selected engine (if required)
4. Test the connection

### Available Engines:
- **Apple Intelligence**: On-device, no setup required
- **OpenAI**: Cloud-based, requires API key
- **Whisper (Local)**: Local server, requires setup
- **Whisper (Wyoming)**: Local streaming, requires setup
- **AWS Transcribe**: Cloud-based, requires AWS account

### Large File Processing
- **Automatic Chunking**: Files over 5 minutes are automatically split
- **Progress Tracking**: Real-time progress updates
- **Background Processing**: Continues when app is minimized
- **Timeout Settings**: Configurable processing time limits

## 📊 Working with Summaries

### Viewing Summaries
1. Tap the "Summaries" tab
2. Browse your recordings with AI-generated summaries
3. Tap any summary to view details

### Summary Features
- **Expandable Sections**: Tap to expand/collapse sections
- **Task Extraction**: AI-identified actionable items
- **Reminder Detection**: Time-sensitive reminders
- **Priority Indicators**: Color-coded task priorities
- **Location Maps**: Interactive maps showing recording location

### Editing Recording Metadata

#### Changing Recording Title
1. Open a summary
2. Scroll to "Titles" section
3. Tap "Edit" next to any title
4. Enter new title or select from AI-generated alternatives
5. Tap "Use This Title"

#### Setting Custom Date & Time
1. Open a summary
2. Scroll to "Recording Date & Time" section
3. Tap "Set Custom Date & Time"
4. Use date and time pickers
5. Tap "Save"

#### Adding/Editing Location
1. Open a summary
2. In the location section, tap "Add Location" or "Edit Location"
3. Choose from:
   - **Current Location**: Use device GPS
   - **Map Selection**: Pick location on map
   - **Manual Entry**: Enter coordinates manually
4. Tap "Save"

## 🎵 Audio Playback

### Basic Playback
1. Go to "Recordings" tab
2. Tap any recording to play
3. Use playback controls:
   - **Play/Pause**: Center button
   - **Skip 15s**: Side buttons
   - **Scrub**: Drag progress bar

### Advanced Playback
- **Seek Control**: Drag the scrubber for precise positioning
- **Background Playback**: Audio continues when app is minimized
- **Audio Session Management**: Handles interruptions gracefully

## ⚙️ Settings & Configuration

### Audio Settings
- **Quality**: Low (64kbps), Medium (128kbps), High (256kbps)
- **Input Selection**: Built-in mic, Bluetooth, USB devices
- **Mixed Audio**: Record without interrupting system audio
- **Background Recording**: Continue recording when app is minimized

### AI Settings
- **Engine Selection**: Choose your preferred AI engine
- **Model Configuration**: Adjust settings for selected engine
- **Connection Testing**: Verify API connectivity
- **Batch Regeneration**: Update all summaries with new engine

### Background Processing
- **Job Management**: View active and completed jobs
- **Progress Tracking**: Monitor long-running operations
- **Error Recovery**: Automatic retry and error handling
- **Performance Monitoring**: Real-time metrics

### Data Management
- **Migration Tools**: Import legacy data
- **Database Maintenance**: Clear and repair data
- **File Relationships**: Manage audio, transcript, and summary files
- **Debug Tools**: Advanced troubleshooting options

## 🔧 Troubleshooting

### Common Issues

#### Recording Problems
- **No Audio**: Check microphone permissions
- **Poor Quality**: Adjust audio quality settings
- **Background Recording**: Enable in settings

#### AI Engine Issues
- **Connection Failed**: Check internet and API keys
- **Timeout Errors**: Increase timeout settings
- **Authentication Errors**: Verify API credentials

#### Transcription Problems
- **No Transcription**: Check engine configuration
- **Poor Quality**: Try different engine or model
- **Large File Issues**: Enable chunking for files over 5 minutes

#### Data Issues
- **Missing Recordings**: Use Data Migration tools
- **Corrupted Data**: Clear and re-import data
- **Sync Problems**: Check iCloud settings

### Performance Optimization
- **Battery Life**: Use local engines for offline processing
- **Memory Usage**: Close other apps during large file processing
- **Storage**: Regularly clean up old recordings
- **Network**: Use local engines to reduce data usage

## 📱 Advanced Features

### Background Processing
- **Job Queue**: Multiple operations run in background
- **Progress Tracking**: Real-time updates for long operations
- **Error Recovery**: Automatic retry for failed operations
- **Stale Job Cleanup**: Automatic cleanup of abandoned jobs

### File Management
- **Import/Export**: Support for various audio formats
- **File Relationships**: Maintains connections between audio, transcripts, and summaries
- **Orphaned File Detection**: Identifies and manages disconnected files
- **Selective Deletion**: Choose what to keep when deleting recordings

### Location Intelligence
- **GPS Integration**: Automatic location capture
- **Reverse Geocoding**: Converts coordinates to addresses
- **Interactive Maps**: View recording locations
- **Manual Location**: Add locations after recording

### Data Migration
- **Legacy Import**: Migrate from old file-based storage
- **Data Integrity**: Validate and repair data relationships
- **Batch Operations**: Process multiple files at once
- **Progress Tracking**: Monitor migration progress

## 🎯 Best Practices

### Recording
- **Environment**: Record in quiet environments for best quality
- **Distance**: Keep microphone 6-12 inches from mouth
- **Duration**: Break long recordings into segments
- **Background**: Minimize background noise

### AI Configuration
- **Privacy**: Use local engines for sensitive content
- **Cost**: Start with free engines, upgrade as needed
- **Quality**: Experiment with different models for best results
- **Reliability**: Have backup engines configured

### Data Management
- **Regular Backups**: Export important recordings
- **Cleanup**: Remove old recordings periodically
- **Organization**: Use descriptive titles for easy finding
- **Metadata**: Add location and custom dates for context

### Performance
- **Battery**: Use local engines when battery is low
- **Storage**: Monitor available space
- **Network**: Use local engines when internet is slow
- **Memory**: Close other apps during processing

## 🔗 External Resources

### AI Service Documentation
- **OpenAI**: [platform.openai.com/docs](https://platform.openai.com/docs)
- **Google AI**: [ai.google.dev](https://ai.google.dev)
- **AWS Bedrock**: [docs.aws.amazon.com/bedrock](https://docs.aws.amazon.com/bedrock)
- **AWS Transcribe**: [docs.aws.amazon.com/transcribe](https://docs.aws.amazon.com/transcribe)

### Local Server Setup
- **Whisper ASR**: [github.com/ahmetoner/whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice)
- **Wyoming Protocol**: [github.com/rhasspy/wyoming](https://github.com/rhasspy/wyoming)
- **Ollama**: [ollama.com](https://www.ollama.com)

### Support
- **GitHub Issues**: Report bugs and request features
- **Documentation**: Check the README for technical details
- **Community**: Join discussions and share tips

---

**Audio Journal** - Transform your spoken words into actionable intelligence with advanced AI processing and comprehensive data management. 🎯✨
