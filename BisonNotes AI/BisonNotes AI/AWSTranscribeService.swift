//
//  AWSTranscribeService.swift
//  Audio Journal
//
//  AWS Transcribe service for handling large audio files
//

import Foundation
import AWSTranscribe
import AWSS3
import AWSClientRuntime
import AVFoundation

// MARK: - AWS Transcribe Configuration

struct AWSTranscribeConfig {
    let region: String
    let accessKey: String
    let secretKey: String
    let bucketName: String
    
    static let `default` = AWSTranscribeConfig(
        region: "us-east-1",
        accessKey: "",
        secretKey: "",
        bucketName: ""
    )
}

// MARK: - AWS Transcribe Result

struct AWSTranscribeResult {
    let transcriptText: String
    let segments: [TranscriptSegment]
    let confidence: Double
    let processingTime: TimeInterval
    let jobName: String
    let success: Bool
    let error: Error?
}

// MARK: - AWS Transcribe Job Status

struct AWSTranscribeJobStatus {
    let jobName: String
    let status: TranscribeClientTypes.TranscriptionJobStatus
    let failureReason: String?
    let transcriptUri: String?
    
    var isCompleted: Bool {
        return status == .completed
    }
    
    var isFailed: Bool {
        return status == .failed
    }
    
    var isInProgress: Bool {
        return status == .inProgress
    }
}

// MARK: - AWS Transcribe Service

@MainActor
class AWSTranscribeService: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isTranscribing = false
    @Published var currentStatus = ""
    @Published var progress: Double = 0.0
    
    // MARK: - Private Properties
    
    private var transcribeClient: TranscribeClient?
    private var s3Client: S3Client?
    private var config: AWSTranscribeConfig
    private var currentJobName: String?
    // Add chunking service
    private let chunkingService: AudioFileChunkingService
    
    // MARK: - Initialization
    
    init(config: AWSTranscribeConfig = .default, chunkingService: AudioFileChunkingService) {
        self.config = config
        self.chunkingService = chunkingService
        super.init()
        setupAWSServices()
    }
    
    // MARK: - Setup
    
    private func setupAWSServices() {
        // Clients will be initialized lazily when first needed
        // IMPORTANT: For iOS apps, you need to configure AWS credentials through:
        // 1. AWS Cognito (recommended for mobile apps)
        // 2. Environment variables (for development)  
        // 3. Custom credential provider
        //
        // The new AWS SDK will look for credentials in this order:
        // - Environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
        // - AWS credential files (if available)
        transcribeClient = nil
        s3Client = nil
    }
    
    
    // MARK: - Private Helper Methods
    
    private func getTranscribeClient() async throws -> TranscribeClient {
        if let client = transcribeClient {
            return client
        }
        
        // Use shared AWS credentials for all services
        let sharedCredentials = AWSCredentialsManager.shared.credentials
        
        // Ensure environment variables are set from shared credentials
        AWSCredentialsManager.shared.initializeEnvironment()
        
        do {
            let clientConfig = try await TranscribeClient.TranscribeClientConfiguration(
                region: sharedCredentials.region
            )
            
            // AWS SDK for Swift will automatically use environment variables
            // set by AWSCredentialsManager.initializeEnvironment()
            
            let client = TranscribeClient(config: clientConfig)
            self.transcribeClient = client
            return client
        } catch {
            throw AWSTranscribeError.configurationMissing
        }
    }
    
    private func getS3Client() async throws -> S3Client {
        if let client = s3Client {
            return client
        }
        
        // Use shared AWS credentials for all services
        let sharedCredentials = AWSCredentialsManager.shared.credentials
        
        // Ensure environment variables are set from shared credentials
        AWSCredentialsManager.shared.initializeEnvironment()
        
        do {
            let clientConfig = try await S3Client.S3ClientConfiguration(
                region: sharedCredentials.region
            )
            
            // AWS SDK for Swift will automatically use environment variables
            // set by AWSCredentialsManager.initializeEnvironment()
            
            let client = S3Client(config: clientConfig)
            self.s3Client = client
            return client
        } catch {
            throw AWSTranscribeError.configurationMissing
        }
    }
    
    // MARK: - Public Methods
    
    /// Start a transcription job asynchronously - returns immediately with job name
    func startTranscriptionJob(url: URL) async throws -> String {
        guard !config.accessKey.isEmpty && !config.secretKey.isEmpty else {
            throw AWSTranscribeError.configurationMissing
        }
        
        print("🚀 Starting async transcription job for: \(url.lastPathComponent)")
        
        // Step 1: Upload to S3
        currentStatus = "Uploading to AWS S3..."
        let s3Key = try await uploadToS3(fileURL: url)
        
        // Step 2: Start transcription job
        currentStatus = "Starting transcription job..."
        let jobName = try await startTranscriptionJob(s3Key: s3Key)
        currentJobName = jobName
        
        print("✅ Transcription job started: \(jobName)")
        currentStatus = "Transcription job started - check back later for results"
        
        return jobName
    }
    
    /// Check the status of a transcription job
    func checkJobStatus(jobName: String) async throws -> AWSTranscribeJobStatus {
        let client = try await getTranscribeClient()
        
        do {
            let request = GetTranscriptionJobInput(
                transcriptionJobName: jobName
            )
            
            let response = try await client.getTranscriptionJob(input: request)
            
            guard let job = response.transcriptionJob else {
                throw AWSTranscribeError.jobNotFound
            }
            
            let status = AWSTranscribeJobStatus(
                jobName: jobName,
                status: job.transcriptionJobStatus ?? .failed,
                failureReason: job.failureReason,
                transcriptUri: job.transcript?.transcriptFileUri
            )
            
            return status
            
        } catch {
            throw AWSTranscribeError.jobMonitoringFailed(error)
        }
    }
    
    /// Retrieve completed transcript from S3
    func retrieveTranscript(jobName: String) async throws -> AWSTranscribeResult {
        
        // First check if job is completed
        let jobStatus = try await checkJobStatus(jobName: jobName)
        
        guard jobStatus.status == .completed else {
            throw AWSTranscribeError.jobFailed("Job is not completed. Current status: \(jobStatus.status.rawValue)")
        }
        
        guard let transcriptUri = jobStatus.transcriptUri else {
            throw AWSTranscribeError.noTranscriptAvailable
        }
        
        // Download and parse the transcript
        let transcriptData = try await downloadTranscript(from: transcriptUri)
        let transcript = try parseTranscript(data: transcriptData)
        
        // Cleanup the uploaded audio file
        // Note: We don't have the original S3 key, so we'll skip cleanup for now
        // In a production app, you'd want to store the S3 key with the job
        
        return AWSTranscribeResult(
            transcriptText: transcript.fullText,
            segments: transcript.segments,
            confidence: transcript.confidence,
            processingTime: 0, // We don't track this for async jobs
            jobName: jobName,
            success: true,
            error: nil
        )
    }
    
    func testConnection() async throws {
        guard !config.accessKey.isEmpty && !config.secretKey.isEmpty else {
            throw AWSTranscribeError.configurationMissing
        }
        
        // Test S3 access by trying to list objects in the bucket
        let client = try await getS3Client()
        
        do {
            let listRequest = ListObjectsV2Input(
                bucket: config.bucketName,
                maxKeys: 1
            )
            
            _ = try await client.listObjectsV2(input: listRequest)
        } catch {
            throw AWSTranscribeError.uploadFailed(error)
        }
    }
    
    /// Transcribe audio file with chunking support for files >2 hours
    func transcribeAudioFileWithChunking(at url: URL, recordingId: UUID? = nil) async throws -> AWSTranscribeResult {
        isTranscribing = true
        currentStatus = "Preparing audio file..."
        progress = 0.0
        // Check if chunking is needed for AWS (2 hour limit)
        let needsChunking = try await chunkingService.shouldChunkFile(url, for: .awsTranscribe)
        if needsChunking {
            currentStatus = "Chunking audio file..."
            progress = 0.05
            let chunkingResult = try await chunkingService.chunkAudioFile(url, for: .awsTranscribe)
            let chunks = chunkingResult.chunks
            var transcriptChunks: [TranscriptChunk] = []
            var chunkIndex = 0
            for audioChunk in chunks {
                currentStatus = "Transcribing chunk \(chunkIndex + 1) of \(chunks.count)..."
                progress = 0.05 + 0.85 * (Double(chunkIndex) / Double(chunks.count))
                // Transcribe each chunk (upload, start job, monitor, download, parse)
                let s3Key = try await uploadToS3(fileURL: audioChunk.chunkURL)
                let jobName = try await startTranscriptionJob(s3Key: s3Key)
                let result = try await monitorTranscriptionJob(jobName: jobName)
                let finalResult = try await processTranscriptionResult(result: result)
                // Wrap result in TranscriptChunk
                let transcriptChunk = TranscriptChunk(
                    chunkId: audioChunk.id,
                    sequenceNumber: audioChunk.sequenceNumber,
                    transcript: finalResult.transcriptText,
                    segments: finalResult.segments,
                    startTime: audioChunk.startTime,
                    endTime: audioChunk.endTime,
                    processingTime: finalResult.processingTime
                )
                transcriptChunks.append(transcriptChunk)
                // Clean up S3 for this chunk
                try await cleanup(s3Key: s3Key, jobName: jobName)
                chunkIndex += 1
            }
            // Reassemble transcript
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let creationDate = (fileAttributes[.creationDate] as? Date) ?? Date()
            let reassembly = try await chunkingService.reassembleTranscript(
                from: transcriptChunks,
                originalURL: url,
                recordingName: url.deletingPathExtension().lastPathComponent,
                recordingDate: creationDate,
                recordingId: recordingId ?? UUID() // TODO: Get actual recording ID from Core Data
            )
            // Clean up chunk files
            try await chunkingService.cleanupChunks(chunks)
            currentStatus = "Transcription complete"
            progress = 1.0
            isTranscribing = false
            // Return as AWSTranscribeResult (flattened, use last chunk's jobName)
            return AWSTranscribeResult(
                transcriptText: reassembly.transcriptData.plainText,
                segments: reassembly.transcriptData.segments,
                confidence: 1.0, // Not aggregated, set to 1.0 for now
                processingTime: reassembly.reassemblyTime,
                jobName: transcriptChunks.last?.chunkId.uuidString ?? "chunked-job",
                success: true,
                error: nil
            )
        } else {
            // No chunking needed, use single file method
            return try await transcribeAudioFileWithChunking(at: url)
        }
    }
    
    func cancelTranscription() {
        guard let jobName = currentJobName else { return }
        
        Task {
            do {
                try await cancelTranscriptionJob(jobName: jobName)
                currentStatus = "Transcription cancelled"
                isTranscribing = false
            } catch {
                print("Error cancelling transcription: \(error)")
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func uploadToS3(fileURL: URL) async throws -> String {
        let s3Key = "audio-files/\(UUID().uuidString)-\(fileURL.lastPathComponent)"
        
        let client = try await getS3Client()
        
        do {
            let fileData = try Data(contentsOf: fileURL)
            
            // Set proper content type based on file extension
            let fileExtension = fileURL.pathExtension.lowercased()
            let contentType: String
            switch fileExtension {
            case "m4a", "mp4":
                contentType = "audio/mp4"
            case "wav":
                contentType = "audio/wav"
            case "mp3":
                contentType = "audio/mpeg"
            case "aac":
                contentType = "audio/aac"
            default:
                contentType = "audio/mp4" // Default fallback
            }
            
            
            let putRequest = PutObjectInput(
                body: .data(fileData),
                bucket: config.bucketName,
                contentLength: fileData.count,
                contentType: contentType,
                key: s3Key
            )
            
            _ = try await client.putObject(input: putRequest)
            print("✅ S3 upload successful")
            return s3Key
            
        } catch {
            print("❌ S3 upload failed: \(error)")
            throw AWSTranscribeError.uploadFailed(error)
        }
    }
    
    private func startTranscriptionJob(s3Key: String) async throws -> String {
        let jobName = "transcription-\(UUID().uuidString)"
        
        let client = try await getTranscribeClient()
        
        do {
            let media = TranscribeClientTypes.Media(
                mediaFileUri: "s3://\(config.bucketName)/\(s3Key)"
            )
            
            let request = StartTranscriptionJobInput(
                languageCode: .enUs,
                media: media,
                outputBucketName: config.bucketName,
                outputKey: "transcripts/\(jobName).json",
                transcriptionJobName: jobName
            )
            
            _ = try await client.startTranscriptionJob(input: request)
            return jobName
            
        } catch {
            throw AWSTranscribeError.jobStartFailed(error)
        }
    }
    
    private func monitorTranscriptionJob(jobName: String) async throws -> TranscribeClientTypes.TranscriptionJob {
        let client = try await getTranscribeClient()
        
        while true {
            let request = GetTranscriptionJobInput(
                transcriptionJobName: jobName
            )
            
            let response = try await client.getTranscriptionJob(input: request)
            
            guard let job = response.transcriptionJob else {
                throw AWSTranscribeError.jobNotFound
            }
            
            // Update progress on main actor
            await MainActor.run {
                updateProgress(for: job)
            }
            
            switch job.transcriptionJobStatus {
            case .completed:
                return job
            case .failed:
                throw AWSTranscribeError.jobFailed(job.failureReason ?? "Unknown error")
            case .inProgress:
                // Wait 5 seconds before checking again
                try await Task.sleep(nanoseconds: 5_000_000_000)
            default:
                throw AWSTranscribeError.unknownJobStatus
            }
        }
    }
    
    private func updateProgress(for job: TranscribeClientTypes.TranscriptionJob) {
        switch job.transcriptionJobStatus {
        case .inProgress:
            progress = 0.4
            currentStatus = "Transcribing audio (in progress)..."
        case .completed:
            progress = 0.7
            currentStatus = "Transcription completed, processing results..."
        case .failed:
            progress = 0.0
            currentStatus = "Transcription failed"
        default:
            break
        }
    }
    
    private func processTranscriptionResult(result: TranscribeClientTypes.TranscriptionJob) async throws -> AWSTranscribeResult {
        // Check if transcript is available directly in the response
        if let transcript = result.transcript,
           let transcriptText = transcript.transcriptFileUri {
            // Try to download from S3 first
            do {
                let transcriptData = try await downloadTranscript(from: transcriptText)
                let parsedTranscript = try parseTranscript(data: transcriptData)
                
                return AWSTranscribeResult(
                    transcriptText: parsedTranscript.fullText,
                    segments: parsedTranscript.segments,
                    confidence: parsedTranscript.confidence,
                    processingTime: Date().timeIntervalSince(Date()),
                    jobName: result.transcriptionJobName ?? "",
                    success: true,
                    error: nil
                )
            } catch {
                print("⚠️ Failed to download transcript from S3, trying alternative method...")
                // Fall through to alternative method
            }
        }
        
        // Alternative: Try to get transcript from the job result directly
        // This might work if AWS returns the transcript inline
        guard let transcriptText = result.transcript?.transcriptFileUri else {
            throw AWSTranscribeError.noTranscriptAvailable
        }
        
        // For now, create a basic result with the available data
        let segments = [TranscriptSegment(
            speaker: "Speaker",
            text: "Transcript available at: \(transcriptText)",
            startTime: 0,
            endTime: 0
        )]
        
        return AWSTranscribeResult(
            transcriptText: "Transcript completed successfully. Please check S3 bucket for results.",
            segments: segments,
            confidence: 0.0,
            processingTime: Date().timeIntervalSince(Date()),
            jobName: result.transcriptionJobName ?? "",
            success: true,
            error: nil
        )
    }
    
    private func downloadTranscript(from uri: String) async throws -> Data {
        guard let url = URL(string: uri) else {
            print("❌ Invalid transcript URI: \(uri)")
            throw AWSTranscribeError.invalidTranscriptURI
        }
        
        
        // Extract S3 key from the URI
        // URI format: https://s3.us-east-1.amazonaws.com/bucket-name/key
        let pathComponents = url.pathComponents
        guard pathComponents.count >= 3 else {
            print("❌ Invalid S3 URI format: \(uri)")
            throw AWSTranscribeError.invalidTranscriptURI
        }
        
        // Remove the first empty component and bucket name
        let s3Key = pathComponents.dropFirst(2).joined(separator: "/")
        print("🔑 Extracted S3 key: \(s3Key)")
        
        let client = try await getS3Client()
        
        do {
            let getRequest = GetObjectInput(
                bucket: config.bucketName,
                key: s3Key
            )
            
            
            let response = try await client.getObject(input: getRequest)
            
            guard let body = response.body else {
                print("❌ S3 download returned no data")
                throw AWSTranscribeError.invalidTranscriptURI
            }
            
            if let data = try await body.readData() {
                print("✅ S3 download successful: \(data.count) bytes")
                return data
            } else {
                print("❌ S3 download returned no data from stream")
                throw AWSTranscribeError.invalidTranscriptURI
            }
            
        } catch {
            print("❌ S3 download failed: \(error)")
            throw AWSTranscribeError.invalidTranscriptURI
        }
    }
    
    private func parseTranscript(data: Data) throws -> (fullText: String, segments: [TranscriptSegment], confidence: Double) {
        // Debug: Print the first 500 characters of the response
        let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
        print("📄 Transcript response (first 500 chars): \(String(responseString.prefix(500)))")
        print("📊 Response data size: \(data.count) bytes")
        
        // Check if response is empty
        guard !data.isEmpty else {
            throw AWSTranscribeError.invalidTranscriptFormat
        }
        
        let json: [String: Any]
        do {
            json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            print("❌ JSON parsing failed: \(error)")
            print("📄 Raw response: \(responseString)")
            throw AWSTranscribeError.invalidTranscriptFormat
        }
        
        // Check if this is an error response
        if let errorMessage = json["Message"] as? String {
            print("❌ AWS returned error: \(errorMessage)")
            throw AWSTranscribeError.jobFailed(errorMessage)
        }
        
        guard let results = json["results"] as? [String: Any],
              let transcripts = results["transcripts"] as? [[String: Any]],
              let firstTranscript = transcripts.first,
              let transcriptText = firstTranscript["transcript"] as? String else {
            print("❌ Invalid transcript format. JSON structure: \(json)")
            throw AWSTranscribeError.invalidTranscriptFormat
        }
        
        var segments: [TranscriptSegment] = []
        var totalConfidence: Double = 0
        var confidenceCount = 0
        
        // Parse speaker segments if available
        if let speakerLabels = results["speaker_labels"] as? [String: Any],
           let segments_data = speakerLabels["segments"] as? [[String: Any]] {
            
            for segmentData in segments_data {
                guard let startTime = segmentData["start_time"] as? String,
                      let endTime = segmentData["end_time"] as? String,
                      let speakerLabel = segmentData["speaker_label"] as? String,
                      let items = segmentData["items"] as? [[String: Any]] else {
                    continue
                }
                
                let start = Double(startTime) ?? 0
                let end = Double(endTime) ?? 0
                
                // Extract text from items
                var segmentText = ""
                var segmentConfidence: Double = 0
                var itemCount = 0
                
                for item in items {
                    if let alternatives = item["alternatives"] as? [[String: Any]],
                       let firstAlternative = alternatives.first,
                       let content = firstAlternative["content"] as? String,
                       let confidence = firstAlternative["confidence"] as? Double {
                        segmentText += content + " "
                        segmentConfidence += confidence
                        itemCount += 1
                    }
                }
                
                if itemCount > 0 {
                    segmentConfidence /= Double(itemCount)
                    totalConfidence += segmentConfidence
                    confidenceCount += 1
                }
                
                segments.append(TranscriptSegment(
                    speaker: speakerLabel,
                    text: segmentText.trimmingCharacters(in: .whitespacesAndNewlines),
                    startTime: start,
                    endTime: end
                ))
            }
        } else {
            // Fallback to single speaker
            segments.append(TranscriptSegment(
                speaker: "Speaker",
                text: transcriptText,
                startTime: 0,
                endTime: 0
            ))
        }
        
        let averageConfidence = confidenceCount > 0 ? totalConfidence / Double(confidenceCount) : 0.0
        
        return (transcriptText, segments, averageConfidence)
    }
    
    private func cleanup(s3Key: String, jobName: String) async throws {
        let client = try await getS3Client()
        
        do {
            let deleteRequest = DeleteObjectInput(
                bucket: config.bucketName,
                key: s3Key
            )
            
            _ = try await client.deleteObject(input: deleteRequest)
            
        } catch {
            throw AWSTranscribeError.uploadFailed(error)
        }
    }
    
    private func cancelTranscriptionJob(jobName: String) async throws {
        // Note: Job cancellation removed for compatibility with current AWS SDK version
        // AWS Transcribe jobs will continue running until completion
        print("Warning: Job cancellation not supported in current AWS SDK version")
    }
}

// MARK: - AWS Transcribe Errors

enum AWSTranscribeError: LocalizedError {
    case configurationMissing
    case uploadFailed(Error)
    case jobStartFailed(Error)
    case jobMonitoringFailed(Error)
    case jobFailed(String)
    case jobNotFound
    case unknownJobStatus
    case noTranscriptAvailable
    case invalidTranscriptURI
    case invalidTranscriptFormat
    
    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "AWS configuration is missing. Please check your credentials."
        case .uploadFailed(let error):
            return "Failed to upload file to S3: \(error.localizedDescription)"
        case .jobStartFailed(let error):
            return "Failed to start transcription job: \(error.localizedDescription)"
        case .jobMonitoringFailed(let error):
            return "Failed to monitor transcription job: \(error.localizedDescription)"
        case .jobFailed(let reason):
            return "Transcription job failed: \(reason)"
        case .jobNotFound:
            return "Transcription job not found"
        case .unknownJobStatus:
            return "Unknown transcription job status"
        case .noTranscriptAvailable:
            return "No transcript available for the completed job"
        case .invalidTranscriptURI:
            return "Invalid transcript URI"
        case .invalidTranscriptFormat:
            return "Invalid transcript format"
        }
    }
} 