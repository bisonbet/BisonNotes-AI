# BisonNotes AI - Android Architecture Plan

## Complete architecture design for Android port

---

## Overview

This document defines the complete architecture for the BisonNotes AI Android app, following modern Android development best practices with Clean Architecture, MVVM pattern, and Jetpack components.

---

## Architecture Layers

### 1. Presentation Layer (UI)
- **Framework**: Jetpack Compose
- **Pattern**: MVVM (Model-View-ViewModel)
- **Navigation**: Jetpack Navigation Compose
- **State Management**: StateFlow + Compose State

### 2. Domain Layer (Business Logic)
- **Use Cases**: Single-responsibility interactors
- **Repositories**: Abstract data access
- **Models**: Domain entities and data classes

### 3. Data Layer (Persistence & Network)
- **Local Database**: Room
- **Network**: Retrofit + OkHttp
- **File Storage**: Android File System
- **Preferences**: DataStore (Preferences)

### 4. Service Layer (Background Work)
- **Background Jobs**: WorkManager
- **Foreground Services**: For active recording
- **Notifications**: NotificationManager

---

## Detailed Layer Architecture

### Presentation Layer

```
app/src/main/java/com/bisonnotesai/android/
├── ui/
│   ├── MainActivity.kt
│   ├── navigation/
│   │   ├── NavGraph.kt
│   │   ├── NavRoutes.kt
│   │   └── NavHost.kt
│   ├── recordings/
│   │   ├── RecordingsScreen.kt
│   │   ├── RecordingsViewModel.kt
│   │   ├── components/
│   │   │   ├── RecordingItem.kt
│   │   │   ├── RecordingControls.kt
│   │   │   └── AudioWaveform.kt
│   │   └── RecordingsState.kt
│   ├── summaries/
│   │   ├── SummariesScreen.kt
│   │   ├── SummariesViewModel.kt
│   │   ├── SummaryDetailScreen.kt
│   │   ├── components/
│   │   │   ├── SummaryCard.kt
│   │   │   ├── TaskList.kt
│   │   │   ├── ReminderList.kt
│   │   │   └── MarkdownView.kt
│   │   └── SummariesState.kt
│   ├── transcripts/
│   │   ├── TranscriptsScreen.kt
│   │   ├── TranscriptsViewModel.kt
│   │   ├── TranscriptDetailScreen.kt
│   │   ├── components/
│   │   │   ├── TranscriptSegment.kt
│   │   │   └── SpeakerLabel.kt
│   │   └── TranscriptsState.kt
│   ├── settings/
│   │   ├── SettingsScreen.kt
│   │   ├── SettingsViewModel.kt
│   │   ├── ai/
│   │   │   ├── AIEngineSettingsScreen.kt
│   │   │   ├── OpenAISettingsScreen.kt
│   │   │   ├── AWSSettingsScreen.kt
│   │   │   └── OllamaSettingsScreen.kt
│   │   ├── transcription/
│   │   │   └── TranscriptionSettingsScreen.kt
│   │   ├── recording/
│   │   │   └── RecordingSettingsScreen.kt
│   │   └── SettingsState.kt
│   ├── player/
│   │   ├── AudioPlayerView.kt
│   │   ├── AudioPlayerViewModel.kt
│   │   ├── components/
│   │   │   ├── PlaybackControls.kt
│   │   │   ├── SeekBar.kt
│   │   │   └── PlaybackSpeed.kt
│   │   └── AudioPlayerState.kt
│   ├── common/
│   │   ├── components/
│   │   │   ├── LoadingView.kt
│   │   │   ├── ErrorView.kt
│   │   │   ├── EmptyState.kt
│   │   │   └── ConfirmationDialog.kt
│   │   └── utils/
│   │       ├── Formatters.kt
│   │       └── Extensions.kt
│   └── theme/
│       ├── Color.kt
│       ├── Theme.kt
│       ├── Type.kt
│       └── Shape.kt
```

#### ViewModel Pattern

```kotlin
// Base ViewModel
abstract class BaseViewModel : ViewModel() {
    protected val _uiState = MutableStateFlow<UiState>(UiState.Idle)
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    protected fun <T> launchWithLoading(
        block: suspend () -> T,
        onSuccess: (T) -> Unit = {},
        onError: (Throwable) -> Unit = {}
    ) {
        viewModelScope.launch {
            _uiState.value = UiState.Loading
            try {
                val result = block()
                onSuccess(result)
                _uiState.value = UiState.Success
            } catch (e: Exception) {
                _uiState.value = UiState.Error(e.message ?: "Unknown error")
                onError(e)
            }
        }
    }
}

// Example: RecordingsViewModel
class RecordingsViewModel @Inject constructor(
    private val recordingRepository: RecordingRepository,
    private val audioRecorder: AudioRecorder,
    private val locationManager: LocationManager
) : BaseViewModel() {

    private val _recordings = MutableStateFlow<List<RecordingEntity>>(emptyList())
    val recordings: StateFlow<List<RecordingEntity>> = _recordings.asStateFlow()

    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _recordingTime = MutableStateFlow(0L)
    val recordingTime: StateFlow<Long> = _recordingTime.asStateFlow()

    init {
        loadRecordings()
    }

    fun loadRecordings() {
        viewModelScope.launch {
            recordingRepository.getAllRecordings()
                .collect { recordings ->
                    _recordings.value = recordings
                }
        }
    }

    fun startRecording() {
        launchWithLoading(
            block = {
                val location = locationManager.getCurrentLocation()
                audioRecorder.startRecording(location)
                _isRecording.value = true
            },
            onError = { error ->
                // Handle error
            }
        )
    }

    fun stopRecording() {
        launchWithLoading(
            block = {
                val recordingData = audioRecorder.stopRecording()
                recordingRepository.saveRecording(recordingData)
                _isRecording.value = false
            }
        )
    }
}
```

### Domain Layer

```
app/src/main/java/com/bisonnotesai/android/
├── domain/
│   ├── model/
│   │   ├── Recording.kt
│   │   ├── Transcript.kt
│   │   ├── Summary.kt
│   │   ├── ProcessingJob.kt
│   │   ├── LocationData.kt
│   │   └── AudioFile.kt
│   ├── repository/
│   │   ├── RecordingRepository.kt
│   │   ├── TranscriptRepository.kt
│   │   ├── SummaryRepository.kt
│   │   ├── ProcessingJobRepository.kt
│   │   └── PreferencesRepository.kt
│   ├── usecase/
│   │   ├── recording/
│   │   │   ├── StartRecordingUseCase.kt
│   │   │   ├── StopRecordingUseCase.kt
│   │   │   ├── DeleteRecordingUseCase.kt
│   │   │   └── GetRecordingsUseCase.kt
│   │   ├── transcription/
│   │   │   ├── TranscribeAudioUseCase.kt
│   │   │   ├── GetTranscriptUseCase.kt
│   │   │   └── DeleteTranscriptUseCase.kt
│   │   ├── summarization/
│   │   │   ├── GenerateSummaryUseCase.kt
│   │   │   ├── RegenerateSummaryUseCase.kt
│   │   │   └── ExtractTasksUseCase.kt
│   │   └── export/
│   │       ├── ExportAsPdfUseCase.kt
│   │       ├── ExportAsRtfUseCase.kt
│   │       └── ShareRecordingUseCase.kt
│   └── error/
│       ├── AppError.kt
│       └── Result.kt
```

#### Use Case Pattern

```kotlin
// Base Use Case
interface UseCase<in Params, out Result> {
    suspend operator fun invoke(params: Params): Result
}

// Example: TranscribeAudioUseCase
class TranscribeAudioUseCase @Inject constructor(
    private val transcriptionService: TranscriptionService,
    private val recordingRepository: RecordingRepository,
    private val transcriptRepository: TranscriptRepository
) : UseCase<TranscribeAudioUseCase.Params, Result<Transcript>> {

    data class Params(
        val recordingId: String,
        val engine: TranscriptionEngine
    )

    override suspend fun invoke(params: Params): Result<Transcript> {
        return try {
            // Get recording
            val recording = recordingRepository.getRecording(params.recordingId)
                ?: return Result.failure(RecordingNotFoundException())

            // Get transcription service for engine
            val service = transcriptionService.getServiceForEngine(params.engine)

            // Transcribe
            val transcript = service.transcribe(recording.audioFile)

            // Save transcript
            val transcriptEntity = transcriptRepository.saveTranscript(
                recordingId = recording.id,
                transcript = transcript,
                engine = params.engine
            )

            Result.success(transcriptEntity.toDomain())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
```

### Data Layer

```
app/src/main/java/com/bisonnotesai/android/
├── data/
│   ├── local/
│   │   ├── database/
│   │   │   ├── RecordingDatabase.kt
│   │   │   ├── dao/
│   │   │   │   ├── RecordingDao.kt
│   │   │   │   ├── TranscriptDao.kt
│   │   │   │   ├── SummaryDao.kt
│   │   │   │   └── ProcessingJobDao.kt
│   │   │   ├── entity/
│   │   │   │   ├── RecordingEntity.kt
│   │   │   │   ├── TranscriptEntity.kt
│   │   │   │   ├── SummaryEntity.kt
│   │   │   │   └── ProcessingJobEntity.kt
│   │   │   ├── converter/
│   │   │   │   ├── DateConverter.kt
│   │   │   │   └── JsonConverter.kt
│   │   │   └── migration/
│   │   │       └── DatabaseMigrations.kt
│   │   ├── prefs/
│   │   │   ├── PreferencesManager.kt
│   │   │   └── PreferenceKeys.kt
│   │   └── file/
│   │       ├── RecordingFileManager.kt
│   │       └── CacheManager.kt
│   ├── remote/
│   │   ├── api/
│   │   │   ├── OpenAIApi.kt
│   │   │   ├── AWSApi.kt
│   │   │   ├── GoogleAIApi.kt
│   │   │   └── OllamaApi.kt
│   │   ├── model/
│   │   │   ├── request/
│   │   │   │   ├── TranscriptionRequest.kt
│   │   │   │   └── SummarizationRequest.kt
│   │   │   └── response/
│   │   │       ├── TranscriptionResponse.kt
│   │   │       └── SummarizationResponse.kt
│   │   ├── interceptor/
│   │   │   ├── AuthInterceptor.kt
│   │   │   └── LoggingInterceptor.kt
│   │   └── NetworkModule.kt
│   ├── repository/
│   │   ├── RecordingRepositoryImpl.kt
│   │   ├── TranscriptRepositoryImpl.kt
│   │   ├── SummaryRepositoryImpl.kt
│   │   ├── ProcessingJobRepositoryImpl.kt
│   │   └── PreferencesRepositoryImpl.kt
│   └── mapper/
│       ├── RecordingMapper.kt
│       ├── TranscriptMapper.kt
│       └── SummaryMapper.kt
```

#### Room Database

```kotlin
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
@TypeConverters(DateConverter::class, JsonConverter::class)
abstract class RecordingDatabase : RoomDatabase() {

    abstract fun recordingDao(): RecordingDao
    abstract fun transcriptDao(): TranscriptDao
    abstract fun summaryDao(): SummaryDao
    abstract fun processingJobDao(): ProcessingJobDao

    companion object {
        const val DATABASE_NAME = "bisonnotesai.db"
    }
}

// DAO Example
@Dao
interface RecordingDao {

    @Query("SELECT * FROM recordings ORDER BY recordingDate DESC")
    fun getAllRecordings(): Flow<List<RecordingEntity>>

    @Query("SELECT * FROM recordings WHERE id = :id")
    suspend fun getRecording(id: String): RecordingEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertRecording(recording: RecordingEntity)

    @Update
    suspend fun updateRecording(recording: RecordingEntity)

    @Delete
    suspend fun deleteRecording(recording: RecordingEntity)

    @Query("DELETE FROM recordings WHERE id = :id")
    suspend fun deleteRecordingById(id: String)

    @Transaction
    @Query("SELECT * FROM recordings WHERE id = :id")
    suspend fun getRecordingWithTranscriptAndSummary(id: String): RecordingWithDetails?
}

// Relation
data class RecordingWithDetails(
    @Embedded val recording: RecordingEntity,
    @Relation(
        parentColumn = "id",
        entityColumn = "recordingId"
    )
    val transcript: TranscriptEntity?,
    @Relation(
        parentColumn = "id",
        entityColumn = "recordingId"
    )
    val summary: SummaryEntity?
)
```

#### Repository Pattern

```kotlin
interface RecordingRepository {
    fun getAllRecordings(): Flow<List<Recording>>
    suspend fun getRecording(id: String): Recording?
    suspend fun saveRecording(recording: Recording): String
    suspend fun updateRecording(recording: Recording)
    suspend fun deleteRecording(id: String)
    suspend fun getRecordingWithDetails(id: String): RecordingWithDetails?
}

class RecordingRepositoryImpl @Inject constructor(
    private val recordingDao: RecordingDao,
    private val mapper: RecordingMapper,
    private val fileManager: RecordingFileManager
) : RecordingRepository {

    override fun getAllRecordings(): Flow<List<Recording>> {
        return recordingDao.getAllRecordings()
            .map { entities -> entities.map { mapper.toDomain(it) } }
    }

    override suspend fun getRecording(id: String): Recording? {
        return recordingDao.getRecording(id)?.let { mapper.toDomain(it) }
    }

    override suspend fun saveRecording(recording: Recording): String {
        val entity = mapper.toEntity(recording)
        recordingDao.insertRecording(entity)
        return entity.id
    }

    override suspend fun updateRecording(recording: Recording) {
        val entity = mapper.toEntity(recording)
        recordingDao.updateRecording(entity)
    }

    override suspend fun deleteRecording(id: String) {
        recordingDao.getRecording(id)?.let { entity ->
            // Delete audio file
            entity.recordingURL?.let { path ->
                fileManager.deleteRecordingFile(path)
            }
            // Delete database record
            recordingDao.deleteRecording(entity)
        }
    }

    override suspend fun getRecordingWithDetails(id: String): RecordingWithDetails? {
        return recordingDao.getRecordingWithTranscriptAndSummary(id)
    }
}
```

### Service Layer

```
app/src/main/java/com/bisonnotesai/android/
├── service/
│   ├── audio/
│   │   ├── AudioRecorder.kt
│   │   ├── AudioRecorderImpl.kt
│   │   ├── AudioPlayer.kt
│   │   ├── AudioPlayerImpl.kt
│   │   ├── AudioSessionManager.kt
│   │   └── AudioFormat.kt
│   ├── transcription/
│   │   ├── TranscriptionService.kt
│   │   ├── TranscriptionServiceImpl.kt
│   │   ├── engine/
│   │   │   ├── TranscriptionEngine.kt
│   │   │   ├── AndroidSpeechEngine.kt
│   │   │   ├── OpenAIWhisperEngine.kt
│   │   │   ├── LocalWhisperEngine.kt
│   │   │   └── AWSTranscribeEngine.kt
│   │   └── chunking/
│   │       ├── AudioChunker.kt
│   │       └── ChunkProcessor.kt
│   ├── summarization/
│   │   ├── SummarizationService.kt
│   │   ├── SummarizationServiceImpl.kt
│   │   ├── engine/
│   │   │   ├── SummarizationEngine.kt
│   │   │   ├── OpenAISummarizer.kt
│   │   │   ├── ClaudeSummarizer.kt
│   │   │   ├── GeminiSummarizer.kt
│   │   │   └── OllamaSummarizer.kt
│   │   ├── extraction/
│   │   │   ├── TaskExtractor.kt
│   │   │   ├── ReminderExtractor.kt
│   │   │   └── TitleGenerator.kt
│   │   └── prompt/
│   │       ├── PromptBuilder.kt
│   │       └── PromptTemplates.kt
│   ├── location/
│   │   ├── LocationManager.kt
│   │   ├── LocationManagerImpl.kt
│   │   └── LocationData.kt
│   ├── export/
│   │   ├── ExportService.kt
│   │   ├── PdfExporter.kt
│   │   ├── RtfExporter.kt
│   │   └── MarkdownExporter.kt
│   ├── worker/
│   │   ├── TranscriptionWorker.kt
│   │   ├── SummarizationWorker.kt
│   │   ├── CleanupWorker.kt
│   │   └── WorkerFactory.kt
│   ├── foreground/
│   │   ├── RecordingService.kt
│   │   └── NotificationHelper.kt
│   └── notification/
│       ├── NotificationManager.kt
│       └── NotificationChannels.kt
```

#### Audio Recording Service

```kotlin
interface AudioRecorder {
    suspend fun startRecording(location: LocationData?): String
    suspend fun stopRecording(): RecordingData
    suspend fun pauseRecording()
    suspend fun resumeRecording()
    fun getRecordingTime(): Flow<Long>
    fun isRecording(): Flow<Boolean>
}

class AudioRecorderImpl @Inject constructor(
    private val context: Context,
    private val fileManager: RecordingFileManager,
    private val audioSessionManager: AudioSessionManager
) : AudioRecorder {

    private var mediaRecorder: MediaRecorder? = null
    private var recordingStartTime: Long = 0
    private var currentRecordingFile: File? = null

    private val _recordingTime = MutableStateFlow(0L)
    override fun getRecordingTime(): Flow<Long> = _recordingTime.asStateFlow()

    private val _isRecording = MutableStateFlow(false)
    override fun isRecording(): Flow<Boolean> = _isRecording.asStateFlow()

    override suspend fun startRecording(location: LocationData?): String = withContext(Dispatchers.IO) {
        val recordingId = UUID.randomUUID().toString()
        val outputFile = fileManager.createRecordingFile("recording_$recordingId")
        currentRecordingFile = outputFile

        audioSessionManager.requestAudioFocus()

        mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }.apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioEncodingBitRate(128000)
            setAudioSamplingRate(44100)
            setOutputFile(outputFile.absolutePath)

            prepare()
            start()
        }

        recordingStartTime = System.currentTimeMillis()
        _isRecording.value = true

        // Start timer
        startTimerJob()

        recordingId
    }

    override suspend fun stopRecording(): RecordingData = withContext(Dispatchers.IO) {
        mediaRecorder?.apply {
            stop()
            release()
        }
        mediaRecorder = null

        _isRecording.value = false
        audioSessionManager.abandonAudioFocus()

        val duration = (System.currentTimeMillis() - recordingStartTime) / 1000.0
        val file = currentRecordingFile ?: throw IllegalStateException("No recording file")

        RecordingData(
            file = file,
            duration = duration,
            fileSize = file.length()
        )
    }

    private fun startTimerJob() {
        // Timer implementation
    }
}
```

#### Foreground Service for Recording

```kotlin
class RecordingService : Service() {

    private val binder = RecordingBinder()
    private lateinit var notificationHelper: NotificationHelper

    @Inject
    lateinit var audioRecorder: AudioRecorder

    inner class RecordingBinder : Binder() {
        fun getService(): RecordingService = this@RecordingService
    }

    override fun onCreate() {
        super.onCreate()
        notificationHelper = NotificationHelper(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_RECORDING -> startRecording()
            ACTION_STOP_RECORDING -> stopRecording()
            ACTION_PAUSE_RECORDING -> pauseRecording()
        }
        return START_STICKY
    }

    private fun startRecording() {
        val notification = notificationHelper.createRecordingNotification()
        startForeground(NOTIFICATION_ID, notification)

        lifecycleScope.launch {
            audioRecorder.startRecording(null)
        }
    }

    private fun stopRecording() {
        lifecycleScope.launch {
            audioRecorder.stopRecording()
            stopSelf()
        }
    }

    override fun onBind(intent: Intent): IBinder = binder

    companion object {
        const val ACTION_START_RECORDING = "com.bisonnotesai.START_RECORDING"
        const val ACTION_STOP_RECORDING = "com.bisonnotesai.STOP_RECORDING"
        const val ACTION_PAUSE_RECORDING = "com.bisonnotesai.PAUSE_RECORDING"
        const val NOTIFICATION_ID = 1001
    }
}
```

#### WorkManager Background Processing

```kotlin
class TranscriptionWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    @Inject
    lateinit var transcriptionService: TranscriptionService

    @Inject
    lateinit var recordingRepository: RecordingRepository

    override suspend fun doWork(): Result {
        val recordingId = inputData.getString(KEY_RECORDING_ID) ?: return Result.failure()
        val engine = inputData.getString(KEY_ENGINE) ?: return Result.failure()

        setForeground(createForegroundInfo())

        return try {
            // Get recording
            val recording = recordingRepository.getRecording(recordingId)
                ?: return Result.failure()

            // Transcribe
            val engineInstance = TranscriptionEngine.fromString(engine)
            val transcript = transcriptionService.transcribe(recording, engineInstance)

            // Update progress
            setProgress(workDataOf(KEY_PROGRESS to 100))

            Result.success()
        } catch (e: Exception) {
            Result.failure(
                workDataOf(KEY_ERROR to e.message)
            )
        }
    }

    private fun createForegroundInfo(): ForegroundInfo {
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle("Transcribing Audio")
            .setSmallIcon(R.drawable.ic_mic)
            .setProgress(100, 0, false)
            .build()

        return ForegroundInfo(NOTIFICATION_ID, notification)
    }

    companion object {
        const val KEY_RECORDING_ID = "recording_id"
        const val KEY_ENGINE = "engine"
        const val KEY_PROGRESS = "progress"
        const val KEY_ERROR = "error"
        const val CHANNEL_ID = "transcription_channel"
        const val NOTIFICATION_ID = 2001
    }
}
```

### Dependency Injection Layer

```
app/src/main/java/com/bisonnotesai/android/
├── di/
│   ├── AppModule.kt
│   ├── DatabaseModule.kt
│   ├── NetworkModule.kt
│   ├── RepositoryModule.kt
│   ├── ServiceModule.kt
│   ├── UseCaseModule.kt
│   └── WorkerModule.kt
```

#### Hilt Modules

```kotlin
@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideContext(@ApplicationContext context: Context): Context = context

    @Provides
    @Singleton
    fun provideCoroutineScope(): CoroutineScope {
        return CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}

@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): RecordingDatabase {
        return Room.databaseBuilder(
            context,
            RecordingDatabase::class.java,
            RecordingDatabase.DATABASE_NAME
        )
            .fallbackToDestructiveMigration() // TODO: Add proper migrations
            .build()
    }

    @Provides
    fun provideRecordingDao(database: RecordingDatabase): RecordingDao {
        return database.recordingDao()
    }

    @Provides
    fun provideTranscriptDao(database: RecordingDatabase): TranscriptDao {
        return database.transcriptDao()
    }

    @Provides
    fun provideSummaryDao(database: RecordingDatabase): SummaryDao {
        return database.summaryDao()
    }

    @Provides
    fun provideProcessingJobDao(database: RecordingDatabase): ProcessingJobDao {
        return database.processingJobDao()
    }
}

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun provideOkHttpClient(): OkHttpClient {
        return OkHttpClient.Builder()
            .addInterceptor(LoggingInterceptor())
            .connectTimeout(60, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    @Provides
    @Singleton
    fun provideRetrofit(okHttpClient: OkHttpClient): Retrofit {
        return Retrofit.Builder()
            .baseUrl("https://api.openai.com/")
            .client(okHttpClient)
            .addConverterFactory(GsonConverterFactory.create())
            .build()
    }

    @Provides
    @Singleton
    fun provideOpenAIApi(retrofit: Retrofit): OpenAIApi {
        return retrofit.create(OpenAIApi::class.java)
    }
}

@Module
@InstallIn(SingletonComponent::class)
abstract class RepositoryModule {

    @Binds
    @Singleton
    abstract fun bindRecordingRepository(
        impl: RecordingRepositoryImpl
    ): RecordingRepository

    @Binds
    @Singleton
    abstract fun bindTranscriptRepository(
        impl: TranscriptRepositoryImpl
    ): TranscriptRepository

    @Binds
    @Singleton
    abstract fun bindSummaryRepository(
        impl: SummaryRepositoryImpl
    ): SummaryRepository
}
```

---

## Architecture Patterns & Principles

### 1. Clean Architecture
- **Separation of Concerns**: Each layer has distinct responsibilities
- **Dependency Rule**: Dependencies point inward (UI → Domain ← Data)
- **Testability**: Easy to test each layer independently

### 2. MVVM (Model-View-ViewModel)
- **View**: Compose UI (stateless, declarative)
- **ViewModel**: Holds UI state, handles user actions
- **Model**: Domain entities and business logic

### 3. Repository Pattern
- Abstract data sources (local DB, network, files)
- Single source of truth for data
- Easier to swap implementations

### 4. Use Case Pattern
- Encapsulate business logic
- Single responsibility
- Reusable across ViewModels

### 5. Dependency Injection
- Hilt for compile-time DI
- Constructor injection for testability
- Modules for providing dependencies

---

## State Management

### StateFlow Pattern

```kotlin
// ViewModel
class RecordingsViewModel @Inject constructor(
    private val getRecordingsUseCase: GetRecordingsUseCase
) : ViewModel() {

    // Private mutable state
    private val _recordings = MutableStateFlow<UiState<List<Recording>>>(UiState.Loading)
    // Public immutable state
    val recordings: StateFlow<UiState<List<Recording>>> = _recordings.asStateFlow()

    init {
        loadRecordings()
    }

    private fun loadRecordings() {
        viewModelScope.launch {
            getRecordingsUseCase(Unit)
                .collect { result ->
                    _recordings.value = when {
                        result.isSuccess -> UiState.Success(result.getOrNull()!!)
                        result.isFailure -> UiState.Error(result.exceptionOrNull()?.message)
                        else -> UiState.Loading
                    }
                }
        }
    }
}

// UI State sealed class
sealed interface UiState<out T> {
    object Idle : UiState<Nothing>
    object Loading : UiState<Nothing>
    data class Success<T>(val data: T) : UiState<T>
    data class Error(val message: String?) : UiState<Nothing>
}
```

### Compose State Collection

```kotlin
@Composable
fun RecordingsScreen(
    viewModel: RecordingsViewModel = viewModel()
) {
    val recordings by viewModel.recordings.collectAsState()

    when (val state = recordings) {
        is UiState.Loading -> LoadingView()
        is UiState.Success -> RecordingsList(state.data)
        is UiState.Error -> ErrorView(state.message)
        else -> {}
    }
}
```

---

## Navigation Architecture

### Navigation Graph

```kotlin
@Composable
fun NavGraph(
    navController: NavHostController = rememberNavController()
) {
    NavHost(
        navController = navController,
        startDestination = Route.Recordings.route
    ) {
        composable(Route.Recordings.route) {
            RecordingsScreen(
                onNavigateToPlayer = { recordingId ->
                    navController.navigate(Route.Player.createRoute(recordingId))
                }
            )
        }

        composable(
            route = Route.Player.route,
            arguments = listOf(navArgument("recordingId") { type = NavType.StringType })
        ) { backStackEntry ->
            val recordingId = backStackEntry.arguments?.getString("recordingId")
            AudioPlayerScreen(recordingId = recordingId)
        }

        composable(Route.Summaries.route) {
            SummariesScreen()
        }

        composable(Route.Transcripts.route) {
            TranscriptsScreen()
        }

        composable(Route.Settings.route) {
            SettingsScreen()
        }
    }
}

// Routes
sealed class Route(val route: String) {
    object Recordings : Route("recordings")
    object Summaries : Route("summaries")
    object Transcripts : Route("transcripts")
    object Settings : Route("settings")
    object Player : Route("player/{recordingId}") {
        fun createRoute(recordingId: String) = "player/$recordingId"
    }
}
```

---

## Error Handling Strategy

### Result Type

```kotlin
sealed class Result<out T> {
    data class Success<T>(val data: T) : Result<T>()
    data class Error(val exception: Exception) : Result<Nothing>()
    object Loading : Result<Nothing>()
}

// Extension functions
fun <T> Result<T>.onSuccess(action: (T) -> Unit): Result<T> {
    if (this is Result.Success) action(data)
    return this
}

fun <T> Result<T>.onError(action: (Exception) -> Unit): Result<T> {
    if (this is Result.Error) action(exception)
    return this
}
```

### Centralized Error Handling

```kotlin
object ErrorHandler {
    fun handle(error: Throwable): String {
        return when (error) {
            is IOException -> "Network error. Please check your connection."
            is HttpException -> "Server error: ${error.code()}"
            is RecordingException -> "Recording error: ${error.message}"
            else -> "An unexpected error occurred: ${error.message}"
        }
    }
}
```

---

## Performance Considerations

### 1. Database Optimization
- Use indexed columns for frequent queries
- Implement pagination for large lists
- Use Flow for reactive updates

### 2. Memory Management
- Use Coil for image loading (caching)
- Implement audio chunking for large files
- Clear unused resources in ViewModel.onCleared()

### 3. Background Processing
- Use WorkManager for deferrable work
- Implement battery-aware processing
- Respect user's data preferences

### 4. UI Performance
- Use LazyColumn for lists (virtualization)
- Minimize recomposition with keys and remember
- Use derivedStateOf for computed state

---

## Testing Strategy

### Unit Tests
- **ViewModels**: Test business logic with fake repositories
- **Use Cases**: Test with mocked dependencies
- **Repositories**: Test with fake DAOs

### Integration Tests
- **Database**: Test Room DAOs with in-memory DB
- **API**: Test with MockWebServer

### UI Tests
- **Compose**: Use Compose Testing API
- **End-to-End**: Test critical user flows

---

## Security Considerations

### 1. API Keys
- Store in BuildConfig or encrypted SharedPreferences
- Never commit to version control

### 2. File Security
- Use scoped storage (Android 10+)
- Encrypt sensitive recordings if needed

### 3. Network Security
- Use HTTPS for all API calls
- Certificate pinning for production

---

## Build Configuration

### Gradle Structure

```gradle
// app/build.gradle.kts

plugins {
    id("com.android.application")
    kotlin("android")
    kotlin("kapt")
    id("dagger.hilt.android.plugin")
}

android {
    namespace = "com.bisonnotesai.android"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.bisonnotesai.android"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.3"
    }
}

dependencies {
    // Jetpack Compose
    implementation(platform("androidx.compose:compose-bom:2023.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")

    // Lifecycle & ViewModel
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.6.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.6.2")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.7.5")

    // Hilt
    implementation("com.google.dagger:hilt-android:2.48")
    kapt("com.google.dagger:hilt-compiler:2.48")
    implementation("androidx.hilt:hilt-navigation-compose:1.1.0")
    implementation("androidx.hilt:hilt-work:1.1.0")

    // Room
    implementation("androidx.room:room-runtime:2.6.0")
    implementation("androidx.room:room-ktx:2.6.0")
    kapt("androidx.room:room-compiler:2.6.0")

    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // Retrofit & OkHttp
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-gson:2.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // AWS SDK
    implementation("com.amazonaws:aws-android-sdk-core:2.77.0")
    implementation("com.amazonaws:aws-android-sdk-s3:2.77.0")
    implementation("com.amazonaws:aws-android-sdk-transcribe:2.77.0")

    // ExoPlayer
    implementation("androidx.media3:media3-exoplayer:1.2.0")

    // Markdown
    implementation("io.noties.markwon:core:4.6.2")

    // DataStore
    implementation("androidx.datastore:datastore-preferences:1.0.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito.kotlin:mockito-kotlin:5.1.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
```

---

## Summary

This architecture provides:
✅ **Clean separation of concerns**
✅ **Testability at all layers**
✅ **Scalability for future features**
✅ **Modern Android best practices**
✅ **Type-safe navigation and data flow**
✅ **Efficient background processing**
✅ **Robust error handling**

**Estimated Implementation Effort**: 6-12 months with 2-3 developers

---

**Document Version**: 1.0
**Last Updated**: 2025-11-22
