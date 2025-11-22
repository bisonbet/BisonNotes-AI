# BisonNotes AI - iOS to Android Component Mapping

## Complete mapping of iOS components to Android equivalents for the port

---

## 1. Data Layer Mapping

### Core Data → Room Database

| iOS (Core Data) | Android (Room) | Notes |
|----------------|----------------|-------|
| `NSManagedObject` | `@Entity` data class | Room entities are Kotlin data classes |
| `NSManagedObjectContext` | `RoomDatabase` | Database access point |
| `NSFetchRequest` | `@Query` DAO methods | Type-safe queries in DAO |
| `NSPredicate` | SQL WHERE clause | Direct SQL in @Query annotations |
| `NSSortDescriptor` | `ORDER BY` clause | SQL ordering in queries |
| `@FetchRequest` | `Flow<List<Entity>>` | Observable queries with Flow |
| `.cascade` deletion | `onDelete = CASCADE` | Foreign key constraint |
| CloudKit sync | Firebase or custom | Cloud sync replacement |

### Entity Mapping

#### RecordingEntry
```kotlin
// iOS: RecordingEntry (NSManagedObject)
// Android: Room Entity

@Entity(tableName = "recordings")
data class RecordingEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val recordingName: String?,
    val recordingURL: String?,  // Relative path
    val recordingDate: Long,    // Timestamp in millis
    val duration: Double,
    val fileSize: Long,
    val audioQuality: String?,
    val locationLatitude: Double?,
    val locationLongitude: Double?,
    val locationAddress: String?,
    val locationAccuracy: Double?,
    val locationTimestamp: Long?,
    val transcriptId: String?,
    val summaryId: String?,
    val transcriptionStatus: String?,
    val summaryStatus: String?,
    val createdAt: Long,
    val lastModified: Long
)
```

#### TranscriptEntry
```kotlin
@Entity(tableName = "transcripts")
data class TranscriptEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val recordingId: String,
    val segments: String,       // JSON string
    val speakerMappings: String?, // JSON string
    val engine: String?,
    val processingTime: Double,
    val confidence: Double,
    val createdAt: Long,
    val lastModified: Long
)
```

#### SummaryEntry
```kotlin
@Entity(tableName = "summaries")
data class SummaryEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val recordingId: String,
    val transcriptId: String?,
    val summary: String?,
    val tasks: String?,         // JSON array
    val reminders: String?,     // JSON array
    val titles: String?,        // JSON array
    val contentType: String?,
    val aiMethod: String?,
    val originalLength: Int,
    val wordCount: Int,
    val compressionRatio: Double,
    val confidence: Double,
    val processingTime: Double,
    val generatedAt: Long,
    val version: Int
)
```

#### ProcessingJobEntry
```kotlin
@Entity(tableName = "processing_jobs")
data class ProcessingJobEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val recordingId: String?,
    val jobType: String,
    val engine: String,
    val recordingURL: String?,
    val recordingName: String?,
    val status: String,
    val progress: Double,
    val error: String?,
    val startTime: Long,
    val completionTime: Long?,
    val lastModified: Long
)
```

### Database Manager Mapping

| iOS | Android | Implementation |
|-----|---------|----------------|
| `CoreDataManager` | `RecordingDatabase` + DAOs | Room database with DAO pattern |
| `PersistenceController` | `DatabaseProvider` singleton | Provides DB instance |
| `AppDataCoordinator` | `RecordingRepository` | Repository pattern for data access |
| `DataMigrationManager` | `MigrationHelper` | Room migration strategy |

```kotlin
// Android Room Database
@Database(
    entities = [
        RecordingEntity::class,
        TranscriptEntity::class,
        SummaryEntity::class,
        ProcessingJobEntity::class
    ],
    version = 1,
    exportSchema = true
)
abstract class RecordingDatabase : RoomDatabase() {
    abstract fun recordingDao(): RecordingDao
    abstract fun transcriptDao(): TranscriptDao
    abstract fun summaryDao(): SummaryDao
    abstract fun processingJobDao(): ProcessingJobDao
}
```

---

## 2. UI Layer Mapping

### SwiftUI → Jetpack Compose

| iOS (SwiftUI) | Android (Compose) | Notes |
|---------------|-------------------|-------|
| `View` protocol | `@Composable` function | Declarative UI |
| `@State` | `remember { mutableStateOf() }` | Local state |
| `@Published` | `StateFlow` / `MutableStateFlow` | Observable state |
| `@StateObject` | `viewModel()` | ViewModel integration |
| `@ObservedObject` | `collectAsState()` | Observe state changes |
| `@EnvironmentObject` | `CompositionLocal` or ViewModel | Dependency injection |
| `@Binding` | Pass `MutableState<T>` | Two-way binding |
| `NavigationView` | `NavHost` + `NavController` | Navigation |
| `TabView` | `Scaffold` + `BottomNavigation` | Tab bar |
| `List` | `LazyColumn` | Scrollable list |
| `ForEach` | `items()` in LazyColumn | List iteration |
| `.sheet()` | `ModalBottomSheet` or Dialog | Modal presentation |
| `.alert()` | `AlertDialog` | Alert dialogs |
| `.onAppear()` | `LaunchedEffect(Unit)` | Lifecycle hook |
| `.onChange()` | `LaunchedEffect(key)` | Observe changes |
| `.task {}` | `LaunchedEffect` with coroutine | Async work |
| `Color` | `Color` (Compose) | Similar API |
| `Image` | `Image` (Compose) | Similar API |
| `Text` | `Text` (Compose) | Similar API |

### View Mapping

#### ContentView
```kotlin
// iOS: ContentView (TabView with 4 tabs)
// Android: MainActivity with BottomNavigation

@Composable
fun MainScreen(navController: NavHostController) {
    val selectedTab = remember { mutableStateOf(0) }

    Scaffold(
        bottomBar = {
            BottomNavigation {
                BottomNavigationItem(
                    selected = selectedTab.value == 0,
                    onClick = { selectedTab.value = 0 },
                    icon = { Icon(Icons.Default.Mic, "Record") },
                    label = { Text("Record") }
                )
                // ... other tabs
            }
        }
    ) { padding ->
        when (selectedTab.value) {
            0 -> RecordingsScreen(padding)
            1 -> SummariesScreen(padding)
            2 -> TranscriptsScreen(padding)
            3 -> SettingsScreen(padding)
        }
    }
}
```

#### RecordingsView
```kotlin
// iOS: RecordingsView with List and recording controls
// Android: RecordingsScreen with LazyColumn

@Composable
fun RecordingsScreen(
    viewModel: AudioRecorderViewModel = viewModel(),
    paddingValues: PaddingValues
) {
    val recordings by viewModel.recordings.collectAsState()
    val isRecording by viewModel.isRecording.collectAsState()

    Column(modifier = Modifier.padding(paddingValues)) {
        // Recording controls
        RecordingControls(
            isRecording = isRecording,
            onStartStop = { viewModel.toggleRecording() }
        )

        // Recordings list
        LazyColumn {
            items(recordings) { recording ->
                RecordingItem(
                    recording = recording,
                    onClick = { viewModel.selectRecording(recording) }
                )
            }
        }
    }
}
```

#### AudioPlayerView
```kotlin
// iOS: AudioPlayerView with AVPlayer
// Android: AudioPlayerView with MediaPlayer/ExoPlayer

@Composable
fun AudioPlayerView(
    audioUrl: String,
    viewModel: AudioPlayerViewModel = viewModel()
) {
    val isPlaying by viewModel.isPlaying.collectAsState()
    val currentPosition by viewModel.currentPosition.collectAsState()
    val duration by viewModel.duration.collectAsState()

    Column {
        // Waveform or progress bar
        LinearProgressIndicator(
            progress = currentPosition / duration.toFloat(),
            modifier = Modifier.fillMaxWidth()
        )

        // Playback controls
        Row {
            IconButton(onClick = { viewModel.seekBackward() }) {
                Icon(Icons.Default.Replay10, "Back 10s")
            }
            IconButton(onClick = { viewModel.togglePlayback() }) {
                Icon(
                    if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                    "Play/Pause"
                )
            }
            IconButton(onClick = { viewModel.seekForward() }) {
                Icon(Icons.Default.Forward10, "Forward 10s")
            }
        }
    }
}
```

#### AITextView (Markdown Rendering)
```kotlin
// iOS: AITextView with MarkdownUI
// Android: Use Markwon library

@Composable
fun AITextView(
    markdown: String,
    modifier: Modifier = Modifier
) {
    // Option 1: Use Markwon (most feature-complete)
    AndroidView(
        factory = { context ->
            TextView(context).apply {
                val markwon = Markwon.create(context)
                markwon.setMarkdown(this, markdown)
            }
        },
        modifier = modifier
    )

    // Option 2: Use Compose-based markdown library (if available)
    // MarkdownText(markdown = markdown, modifier = modifier)
}
```

---

## 3. Audio Layer Mapping

### AVFoundation → Android Audio APIs

| iOS | Android | Notes |
|-----|---------|-------|
| `AVAudioRecorder` | `MediaRecorder` | Basic recording |
| `AVAudioRecorder` | `AudioRecord` | Low-level recording |
| `AVAudioPlayer` | `MediaPlayer` | Basic playback |
| `AVAudioPlayer` | `ExoPlayer` | Advanced playback |
| `AVAudioSession` | `AudioManager` | Audio session management |
| `AVAudioEngine` | Oboe library | Low-latency audio |
| `.m4a` format | `.m4a` or `.mp4` | Same container |
| Audio interruptions | `AudioManager.OnAudioFocusChangeListener` | Handle interruptions |

### Audio Recording Implementation

```kotlin
// iOS: AudioRecorderViewModel with AVAudioRecorder
// Android: AudioRecorderViewModel with MediaRecorder

class AudioRecorderViewModel @Inject constructor(
    private val repository: RecordingRepository,
    private val locationManager: LocationManager
) : ViewModel() {

    private var mediaRecorder: MediaRecorder? = null
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _recordingTime = MutableStateFlow(0L)
    val recordingTime: StateFlow<Long> = _recordingTime.asStateFlow()

    fun startRecording(context: Context) {
        val outputFile = File(context.filesDir, "recording_${System.currentTimeMillis()}.m4a")

        mediaRecorder = MediaRecorder().apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioEncodingBitRate(128000)
            setAudioSamplingRate(44100)
            setOutputFile(outputFile.absolutePath)
            prepare()
            start()
        }

        _isRecording.value = true
        startTimer()
    }

    fun stopRecording() {
        mediaRecorder?.apply {
            stop()
            release()
        }
        mediaRecorder = null
        _isRecording.value = false
        stopTimer()
    }
}
```

### Audio Playback Implementation

```kotlin
// iOS: AVAudioPlayer
// Android: ExoPlayer (recommended) or MediaPlayer

class AudioPlayerViewModel @Inject constructor() : ViewModel() {
    private var exoPlayer: ExoPlayer? = null

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()

    private val _currentPosition = MutableStateFlow(0L)
    val currentPosition: StateFlow<Long> = _currentPosition.asStateFlow()

    fun initPlayer(context: Context, audioUrl: String) {
        exoPlayer = ExoPlayer.Builder(context).build().apply {
            val mediaItem = MediaItem.fromUri(audioUrl)
            setMediaItem(mediaItem)
            prepare()

            addListener(object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    _isPlaying.value = isPlaying
                }
            })
        }
    }

    fun togglePlayback() {
        exoPlayer?.let {
            if (it.isPlaying) it.pause() else it.play()
        }
    }

    override fun onCleared() {
        exoPlayer?.release()
        super.onCleared()
    }
}
```

---

## 4. Background Processing Mapping

### iOS Background Tasks → Android WorkManager

| iOS | Android | Notes |
|-----|---------|-------|
| `BGTaskScheduler` | `WorkManager` | Deferrable background work |
| `BGProcessingTask` | `Worker` | Long-running work |
| `BGAppRefreshTask` | `PeriodicWorkRequest` | Periodic tasks |
| Background audio | Foreground Service | Notification required |
| `Task {}` (Swift) | `viewModelScope.launch {}` | Coroutines |

### Background Processing Implementation

```kotlin
// iOS: BackgroundProcessingManager
// Android: TranscriptionWorker + SummarizationWorker

class TranscriptionWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val recordingId = inputData.getString(KEY_RECORDING_ID) ?: return Result.failure()
        val engine = inputData.getString(KEY_ENGINE) ?: return Result.failure()

        return try {
            // Show notification for foreground service
            setForeground(createForegroundInfo("Transcribing audio..."))

            // Perform transcription
            val transcriptionService = getTranscriptionService(engine)
            val result = transcriptionService.transcribe(recordingId)

            // Save to database
            saveTranscript(recordingId, result)

            Result.success()
        } catch (e: Exception) {
            Result.failure()
        }
    }

    private fun createForegroundInfo(message: String): ForegroundInfo {
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle("BisonNotes AI")
            .setContentText(message)
            .setSmallIcon(R.drawable.ic_mic)
            .build()

        return ForegroundInfo(NOTIFICATION_ID, notification)
    }
}
```

### Job Queue Management

```kotlin
// iOS: ProcessingJob struct + BackgroundProcessingManager
// Android: WorkManager with constraints

class ProcessingJobManager @Inject constructor(
    private val workManager: WorkManager,
    private val repository: RecordingRepository
) {

    fun enqueueTranscription(recordingId: String, engine: String) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(
                if (engine.isCloudBased()) NetworkType.CONNECTED else NetworkType.NOT_REQUIRED
            )
            .setRequiresBatteryNotLow(true)
            .build()

        val workRequest = OneTimeWorkRequestBuilder<TranscriptionWorker>()
            .setInputData(
                workDataOf(
                    TranscriptionWorker.KEY_RECORDING_ID to recordingId,
                    TranscriptionWorker.KEY_ENGINE to engine
                )
            )
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .build()

        workManager.enqueue(workRequest)
    }

    fun enqueueSummarization(recordingId: String, engine: String) {
        // Chain: wait for transcription to complete first
        val transcriptionWork = /* ... */
        val summarizationWork = OneTimeWorkRequestBuilder<SummarizationWorker>()
            .setInputData(/* ... */)
            .build()

        workManager.beginWith(transcriptionWork)
            .then(summarizationWork)
            .enqueue()
    }
}
```

---

## 5. Location Services Mapping

### CoreLocation → FusedLocationProvider

| iOS | Android | Notes |
|-----|---------|-------|
| `CLLocationManager` | `FusedLocationProviderClient` | Location APIs |
| `CLLocation` | `Location` | Location data |
| `CLGeocoder` | `Geocoder` | Reverse geocoding |
| Location permissions | Runtime permissions | Android 6+ |
| Background location | Background permission | Android 10+ |

```kotlin
// iOS: LocationManager
// Android: LocationManager (different class name to avoid confusion)

class RecordingLocationManager @Inject constructor(
    private val context: Context,
    private val fusedLocationClient: FusedLocationProviderClient,
    private val geocoder: Geocoder
) {

    suspend fun getCurrentLocation(): LocationData? {
        if (!hasLocationPermission()) return null

        return try {
            val location = fusedLocationClient.lastLocation.await()
            location?.let { loc ->
                val address = getAddress(loc.latitude, loc.longitude)
                LocationData(
                    latitude = loc.latitude,
                    longitude = loc.longitude,
                    accuracy = loc.accuracy.toDouble(),
                    timestamp = loc.time,
                    address = address
                )
            }
        } catch (e: Exception) {
            null
        }
    }

    private suspend fun getAddress(lat: Double, lon: Double): String? {
        return withContext(Dispatchers.IO) {
            try {
                val addresses = geocoder.getFromLocation(lat, lon, 1)
                addresses?.firstOrNull()?.getAddressLine(0)
            } catch (e: Exception) {
                null
            }
        }
    }

    private fun hasLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }
}
```

---

## 6. AI Integration Mapping

### Network Layer (Same APIs, Different HTTP clients)

| iOS | Android | Notes |
|-----|---------|-------|
| `URLSession` | `OkHttp` + `Retrofit` | HTTP client |
| `JSONDecoder` | `Gson` or `Moshi` | JSON parsing |
| `Codable` protocol | `@Serializable` (kotlinx) | Serialization |
| Async/await | Coroutines + suspend | Async programming |

### OpenAI Integration

```kotlin
// iOS: OpenAIService with URLSession
// Android: OpenAIService with Retrofit

interface OpenAIApi {
    @POST("v1/audio/transcriptions")
    suspend fun transcribe(
        @Header("Authorization") auth: String,
        @Part file: MultipartBody.Part,
        @Part("model") model: RequestBody
    ): TranscriptionResponse

    @POST("v1/chat/completions")
    suspend fun summarize(
        @Header("Authorization") auth: String,
        @Body request: ChatCompletionRequest
    ): ChatCompletionResponse
}

class OpenAIService @Inject constructor(
    private val api: OpenAIApi,
    private val apiKey: String
) {
    suspend fun transcribe(audioFile: File): Result<String> {
        return try {
            val filePart = audioFile.asRequestBody("audio/m4a".toMediaType())
            val multipartFile = MultipartBody.Part.createFormData("file", audioFile.name, filePart)
            val model = "whisper-1".toRequestBody()

            val response = api.transcribe(
                auth = "Bearer $apiKey",
                file = multipartFile,
                model = model
            )

            Result.success(response.text)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
```

### AWS SDK Integration

```kotlin
// iOS: AWS SDK for iOS
// Android: AWS SDK for Android (same concepts, different API)

class AWSBedrockService @Inject constructor(
    private val credentials: AWSCredentials
) {
    private val client: BedrockRuntimeClient by lazy {
        BedrockRuntimeClient.builder()
            .region(Region.of(credentials.region))
            .credentialsProvider(
                StaticCredentialsProvider.create(
                    AwsBasicCredentials.create(
                        credentials.accessKeyId,
                        credentials.secretAccessKey
                    )
                )
            )
            .build()
    }

    suspend fun invokeClaude(
        prompt: String,
        modelId: String = "anthropic.claude-3-5-sonnet-20241022-v2:0"
    ): Result<String> {
        return withContext(Dispatchers.IO) {
            try {
                val payload = buildClaudePayload(prompt)
                val request = InvokeModelRequest.builder()
                    .modelId(modelId)
                    .body(SdkBytes.fromString(payload, Charsets.UTF_8))
                    .build()

                val response = client.invokeModel(request)
                val responseBody = response.body().asString(Charsets.UTF_8)

                Result.success(parseClaudeResponse(responseBody))
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }
}
```

---

## 7. File Management Mapping

### iOS File System → Android File System

| iOS | Android | Notes |
|-----|---------|-------|
| Documents directory | `context.filesDir` | Internal storage |
| `.documentDirectory` | `context.filesDir` | Private app storage |
| `FileManager` | `File` APIs | File operations |
| Share sheet | Intent with `ACTION_SEND` | Sharing files |
| Document picker | Intent with `ACTION_GET_CONTENT` | File picking |

```kotlin
// iOS: EnhancedFileManager
// Android: RecordingFileManager

class RecordingFileManager @Inject constructor(
    private val context: Context
) {

    private val recordingsDir: File
        get() = File(context.filesDir, "recordings").apply { mkdirs() }

    fun createRecordingFile(name: String): File {
        return File(recordingsDir, "$name.m4a")
    }

    fun getRecordingFile(relativePath: String): File? {
        val file = File(recordingsDir, relativePath)
        return if (file.exists()) file else null
    }

    fun deleteRecordingFile(relativePath: String): Boolean {
        val file = File(recordingsDir, relativePath)
        return file.delete()
    }

    fun getAllRecordingFiles(): List<File> {
        return recordingsDir.listFiles()?.toList() ?: emptyList()
    }

    suspend fun exportAsPDF(summary: SummaryEntity): File {
        return withContext(Dispatchers.IO) {
            val pdfFile = File(context.cacheDir, "summary_${summary.id}.pdf")
            // PDF generation logic using iText or similar
            pdfFile
        }
    }

    fun shareFile(file: File) {
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file
        )

        val intent = Intent(Intent.ACTION_SEND).apply {
            type = getMimeType(file)
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        context.startActivity(Intent.createChooser(intent, "Share via"))
    }
}
```

---

## 8. Settings and Preferences Mapping

### UserDefaults → SharedPreferences / DataStore

| iOS | Android | Notes |
|-----|---------|-------|
| `UserDefaults` | `SharedPreferences` | Legacy approach |
| `@AppStorage` | DataStore Preferences | Modern approach |
| Property wrapper | Kotlin delegates | Similar pattern |

```kotlin
// iOS: @AppStorage property wrapper
// Android: DataStore with extension functions

class UserPreferences @Inject constructor(
    private val dataStore: DataStore<Preferences>
) {
    companion object {
        private val KEY_TRANSCRIPTION_ENGINE = stringPreferencesKey("transcription_engine")
        private val KEY_SUMMARY_ENGINE = stringPreferencesKey("summary_engine")
        private val KEY_LOCATION_ENABLED = booleanPreferencesKey("location_enabled")
        private val KEY_TIME_FORMAT = stringPreferencesKey("time_format")
    }

    val transcriptionEngine: Flow<String> = dataStore.data
        .map { it[KEY_TRANSCRIPTION_ENGINE] ?: "apple" }

    suspend fun setTranscriptionEngine(engine: String) {
        dataStore.edit { it[KEY_TRANSCRIPTION_ENGINE] = engine }
    }

    val locationEnabled: Flow<Boolean> = dataStore.data
        .map { it[KEY_LOCATION_ENABLED] ?: false }

    suspend fun setLocationEnabled(enabled: Boolean) {
        dataStore.edit { it[KEY_LOCATION_ENABLED] = enabled }
    }
}
```

---

## 9. Architecture Pattern Mapping

### iOS MVVM → Android MVVM (with differences)

| iOS Pattern | Android Pattern | Notes |
|-------------|-----------------|-------|
| `@Published` properties | `StateFlow` / `LiveData` | Observable state |
| `ObservableObject` | `ViewModel` | Business logic holder |
| `@StateObject` lifecycle | Compose `viewModel()` | ViewModel scoping |
| Coordinator pattern | Navigation Compose | App navigation |
| Dependency injection | Hilt / Koin | DI framework |

### Project Structure Comparison

```
iOS Structure:                    Android Structure:
─────────────────                ──────────────────────
BisonNotes AI/                   app/
├── Models/                      ├── data/
│   ├── CoreDataManager          │   ├── database/
│   ├── AppDataCoordinator       │   │   ├── RecordingDatabase
│   ├── RecordingWorkflowManager │   │   ├── dao/
│   └── TranscriptData           │   │   └── entities/
├── ViewModels/                  │   ├── repository/
│   └── AudioRecorderViewModel   │   └── model/
├── Views/                       ├── ui/
│   ├── RecordingsView           │   ├── recordings/
│   ├── SummariesView            │   ├── summaries/
│   ├── TranscriptsView          │   ├── transcripts/
│   └── SettingsView             │   ├── settings/
├── OpenAI/                      │   └── theme/
│   ├── OpenAIService            ├── domain/
│   └── OpenAIPromptGenerator    │   ├── usecase/
├── AWS/                         │   └── interactor/
│   ├── AWSBedrockService        ├── service/
│   └── AWSTranscribeService     │   ├── openai/
└── Services/                    │   ├── aws/
    ├── PDFExportService         │   └── transcription/
    └── RTFExportService         └── di/ (Hilt modules)
```

---

## 10. Platform-Specific Features

### iOS-Only Features Requiring Alternatives

| iOS Feature | Android Alternative | Complexity |
|-------------|---------------------|------------|
| Apple Watch app | Wear OS app | High - Separate app |
| Control Center controls | Quick Settings Tile | Medium |
| Action Button | Limited hardware button options | Medium |
| iCloud + CloudKit | Firebase / Google Drive | Medium |
| WidgetKit | App Widgets | Medium |
| SFSpeechRecognizer | Android SpeechRecognizer / ML Kit | Low |
| Apple Intelligence | Google ML Kit / On-device ML | High |
| ShareSheet | Intent system | Low |
| Document picker | Intent system | Low |

---

## 11. Third-Party Library Mapping

| iOS Library | Android Alternative | Purpose |
|-------------|---------------------|---------|
| MarkdownUI | Markwon | Markdown rendering |
| AWS SDK for iOS | AWS SDK for Android | AWS services |
| (none - built-in Speech) | Google ML Kit Speech | On-device speech |
| CloudKit | Firebase Firestore | Cloud sync |
| (none - system APIs) | ExoPlayer | Advanced audio playback |
| (none - system APIs) | Oboe (optional) | Low-latency audio |
| (none - system picker) | Material File Picker | File selection |

---

## 12. Testing Strategy Mapping

| iOS Testing | Android Testing | Framework |
|-------------|-----------------|-----------|
| XCTest | JUnit 4/5 | Unit tests |
| XCUITest | Espresso | UI tests |
| Quick/Nimble | MockK / Mockito | Mocking |
| Preview | Compose Preview | UI preview |

---

## Summary

This comprehensive mapping provides a 1:1 relationship between iOS and Android components for the BisonNotes AI port. Key takeaways:

1. **Data Layer**: Core Data → Room (similar ORM patterns)
2. **UI Layer**: SwiftUI → Jetpack Compose (declarative UI, similar concepts)
3. **Audio**: AVFoundation → MediaRecorder/ExoPlayer (different APIs, same capabilities)
4. **Background Work**: BGTaskScheduler → WorkManager (similar scheduling)
5. **Location**: CoreLocation → FusedLocationProvider (similar APIs)
6. **AI Integration**: Same REST APIs, different HTTP clients (URLSession → OkHttp/Retrofit)
7. **Architecture**: MVVM on both platforms (with platform-specific differences)

**Estimated Lines of Code**: 30,000 - 40,000 LOC for complete port
**Estimated Development Time**: 6-12 months with 2-3 developers
**Complexity Rating**: High (production-grade app with extensive features)

---

**Document Version**: 1.0
**Last Updated**: 2025-11-22
