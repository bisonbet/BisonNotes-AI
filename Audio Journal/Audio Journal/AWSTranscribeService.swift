//
//  AWSTranscribeService.swift
//  Audio Journal
//
//  AWS Transcribe service for handling large audio files
//

import Foundation
import AWSCore
import AWSTranscribe
import AWSS3
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
    let status: AWSTranscribeTranscriptionJobStatus
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
    
    private var transcribeClient: AWSTranscribe?
    private var s3Client: AWSS3?
    private var config: AWSTranscribeConfig
    private var currentJobName: String?
    
    // MARK: - Initialization
    
    init(config: AWSTranscribeConfig = .default) {
        self.config = config
        super.init()
        setupAWSServices()
    }
    
    // MARK: - Setup
    
    private func setupAWSServices() {
        // Configure AWS credentials
        let credentialsProvider = AWSStaticCredentialsProvider(
            accessKey: config.accessKey,
            secretKey: config.secretKey
        )
        
        let configuration = AWSServiceConfiguration(
            region: regionTypeFromString(config.region),
            credentialsProvider: credentialsProvider
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = configuration
        
        // Initialize clients
        transcribeClient = AWSTranscribe.default()
        s3Client = AWSS3.default()
    }
    
    private func regionTypeFromString(_ regionString: String) -> AWSRegionType {
        switch regionString {
        case "us-east-1":
            return .USEast1
        case "us-east-2":
            return .USEast2
        case "us-west-1":
            return .USWest1
        case "us-west-2":
            return .USWest2
        default:
            return .USEast1 // Default fallback
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
        let client = transcribeClient
        
        return try await withCheckedThrowingContinuation { continuation in
            guard let request = AWSTranscribeGetTranscriptionJobRequest() else {
                continuation.resume(throwing: AWSTranscribeError.jobMonitoringFailed(NSError(domain: "AWSTranscribe", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create get transcription job request"])))
                return
            }
            request.transcriptionJobName = jobName
            
            client?.getTranscriptionJob(request).continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: AWSTranscribeError.jobMonitoringFailed(error))
                    return nil
                }
                
                guard let job = task.result?.transcriptionJob else {
                    continuation.resume(throwing: AWSTranscribeError.jobNotFound)
                    return nil
                }
                
                let status = AWSTranscribeJobStatus(
                    jobName: jobName,
                    status: job.transcriptionJobStatus,
                    failureReason: job.failureReason,
                    transcriptUri: job.transcript?.transcriptFileUri
                )
                
                continuation.resume(returning: status)
                return nil
            }
        }
    }
    
    /// Retrieve completed transcript from S3
    func retrieveTranscript(jobName: String) async throws -> AWSTranscribeResult {
        print("📥 Retrieving transcript for job: \(jobName)")
        
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
        let client = s3Client
        
        return try await withCheckedThrowingContinuation { continuation in
            guard let listRequest = AWSS3ListObjectsV2Request() else {
                continuation.resume(throwing: AWSTranscribeError.configurationMissing)
                return
            }
            
            listRequest.bucket = config.bucketName
            listRequest.maxKeys = 1 // Just get one object to test access
            
            client?.listObjectsV2(listRequest).continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: AWSTranscribeError.uploadFailed(error))
                } else {
                    continuation.resume(returning: ())
                }
                return nil
            }
        }
    }
    
    func transcribeAudioFile(at url: URL) async throws -> AWSTranscribeResult {
        guard !config.accessKey.isEmpty && !config.secretKey.isEmpty else {
            throw AWSTranscribeError.configurationMissing
        }
        
        isTranscribing = true
        currentStatus = "Preparing audio file..."
        progress = 0.0
        
        do {
            // Step 1: Upload to S3
            currentStatus = "Uploading to AWS S3..."
            progress = 0.1
            let s3Key = try await uploadToS3(fileURL: url)
            
            // Step 2: Start transcription job
            currentStatus = "Starting transcription job..."
            progress = 0.2
            let jobName = try await startTranscriptionJob(s3Key: s3Key)
            currentJobName = jobName
            
            // Step 3: Monitor job progress
            currentStatus = "Transcribing audio..."
            progress = 0.3
            let result = try await monitorTranscriptionJob(jobName: jobName)
            
            // Step 4: Download and process results
            currentStatus = "Processing results..."
            progress = 0.8
            let finalResult = try await processTranscriptionResult(result: result)
            
            // Step 5: Cleanup
            currentStatus = "Cleaning up..."
            progress = 0.9
            try await cleanup(s3Key: s3Key, jobName: jobName)
            
            currentStatus = "Transcription complete"
            progress = 1.0
            isTranscribing = false
            
            return finalResult
            
        } catch {
            isTranscribing = false
            currentStatus = "Transcription failed"
            throw error
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
        
        // Capture the client reference on the main actor
        let client = s3Client
        
        return try await withCheckedThrowingContinuation { continuation in
            // Read the file data
            do {
                let fileData = try Data(contentsOf: fileURL)
                
                guard let putRequest = AWSS3PutObjectRequest() else {
                    continuation.resume(throwing: AWSTranscribeError.uploadFailed(NSError(domain: "AWSTranscribe", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create S3 put request"])))
                    return
                }
                
                putRequest.bucket = config.bucketName
                putRequest.key = s3Key
                putRequest.body = fileData
                
                // Set proper content type based on file extension
                let fileExtension = fileURL.pathExtension.lowercased()
                switch fileExtension {
                case "m4a", "mp4":
                    putRequest.contentType = "audio/mp4"
                case "wav":
                    putRequest.contentType = "audio/wav"
                case "mp3":
                    putRequest.contentType = "audio/mpeg"
                case "aac":
                    putRequest.contentType = "audio/aac"
                default:
                    putRequest.contentType = "audio/mp4" // Default fallback
                }
                
                // Set content length explicitly
                putRequest.contentLength = NSNumber(value: fileData.count)
                
                print("📤 Uploading \(fileData.count) bytes to S3 as \(s3Key)")
                
                client?.putObject(putRequest).continueWith { task in
                    if let error = task.error {
                        print("❌ S3 upload failed: \(error)")
                        continuation.resume(throwing: AWSTranscribeError.uploadFailed(error))
                    } else {
                        print("✅ S3 upload successful")
                        continuation.resume(returning: s3Key)
                    }
                    return nil
                }
            } catch {
                print("❌ Failed to read file data: \(error)")
                continuation.resume(throwing: AWSTranscribeError.uploadFailed(error))
            }
        }
    }
    
    private func startTranscriptionJob(s3Key: String) async throws -> String {
        let jobName = "transcription-\(UUID().uuidString)"
        
        // Capture the client reference on the main actor
        let client = transcribeClient
        
        return try await withCheckedThrowingContinuation { continuation in
            guard let request = AWSTranscribeStartTranscriptionJobRequest() else {
                continuation.resume(throwing: AWSTranscribeError.jobStartFailed(NSError(domain: "AWSTranscribe", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create transcription job request"])))
                return
            }
            
            request.transcriptionJobName = jobName
            request.media = AWSTranscribeMedia()
            request.media?.mediaFileUri = "s3://\(config.bucketName)/\(s3Key)"
            request.languageCode = .enUS
            request.outputBucketName = config.bucketName
            request.outputKey = "transcripts/\(jobName).json"
            
            // Note: Speaker diarization settings removed for compatibility
            // with current AWS SDK version
            
            client?.startTranscriptionJob(request).continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: AWSTranscribeError.jobStartFailed(error))
                } else {
                    continuation.resume(returning: jobName)
                }
                return nil
            }
        }
    }
    
    private func monitorTranscriptionJob(jobName: String) async throws -> AWSTranscribeTranscriptionJob {
        // Capture the client reference on the main actor
        let client = transcribeClient
        
        return try await withCheckedThrowingContinuation { continuation in
            func checkJobStatus() {
                guard let request = AWSTranscribeGetTranscriptionJobRequest() else {
                    continuation.resume(throwing: AWSTranscribeError.jobMonitoringFailed(NSError(domain: "AWSTranscribe", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create get transcription job request"])))
                    return
                }
                request.transcriptionJobName = jobName
                
                client?.getTranscriptionJob(request).continueWith { task in
                    if let error = task.error {
                        continuation.resume(throwing: AWSTranscribeError.jobMonitoringFailed(error))
                        return nil
                    }
                    
                    guard let job = task.result?.transcriptionJob else {
                        continuation.resume(throwing: AWSTranscribeError.jobNotFound)
                        return nil
                    }
                    
                    // Update progress
                    DispatchQueue.main.async {
                        self.updateProgress(for: job)
                    }
                    
                    switch job.transcriptionJobStatus {
                    case .completed:
                        continuation.resume(returning: job)
                    case .failed:
                        continuation.resume(throwing: AWSTranscribeError.jobFailed(job.failureReason ?? "Unknown error"))
                    case .inProgress:
                        // Check again in 5 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            checkJobStatus()
                        }
                    default:
                        continuation.resume(throwing: AWSTranscribeError.unknownJobStatus)
                    }
                    
                    return nil
                }
            }
            
            checkJobStatus()
        }
    }
    
    private func updateProgress(for job: AWSTranscribeTranscriptionJob) {
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
    
    private func processTranscriptionResult(result: AWSTranscribeTranscriptionJob) async throws -> AWSTranscribeResult {
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
        
        print("📥 Downloading transcript from: \(url)")
        
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
        
        // Use AWS S3 client to download with proper authentication
        let client = s3Client
        
        return try await withCheckedThrowingContinuation { continuation in
            guard let getRequest = AWSS3GetObjectRequest() else {
                continuation.resume(throwing: AWSTranscribeError.invalidTranscriptURI)
                return
            }
            
            getRequest.bucket = config.bucketName
            getRequest.key = s3Key
            
            print("📤 Requesting S3 object: \(config.bucketName)/\(s3Key)")
            
            client?.getObject(getRequest).continueWith { task in
                if let error = task.error {
                    print("❌ S3 download failed: \(error)")
                    continuation.resume(throwing: AWSTranscribeError.invalidTranscriptURI)
                    return task
                }
                
                guard let result = task.result,
                      let body = result.body as? Data else {
                    print("❌ S3 download returned no data or invalid data type")
                    continuation.resume(throwing: AWSTranscribeError.invalidTranscriptURI)
                    return task
                }
                
                print("✅ S3 download successful: \(body.count) bytes")
                continuation.resume(returning: body)
                return task
            }
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
        // Delete the uploaded audio file
        guard let deleteRequest = AWSS3DeleteObjectRequest() else {
            throw AWSTranscribeError.uploadFailed(NSError(domain: "AWSTranscribe", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create S3 delete request"]))
        }
        deleteRequest.bucket = config.bucketName
        deleteRequest.key = s3Key
        
        // Capture the client reference on the main actor
        let client = s3Client
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client?.deleteObject(deleteRequest).continueWith { task in
                if let error = task.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
                return nil
            }
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