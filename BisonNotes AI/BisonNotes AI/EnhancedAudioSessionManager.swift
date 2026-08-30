//
//  EnhancedAudioSessionManager.swift
//  Audio Journal
//
//  Created by Kiro on 7/29/25.
//

import Foundation
import AVFoundation
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
@MainActor
protocol AudioSessionControlling: AnyObject {
    var category: AVAudioSession.Category { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    var availableInputs: [AVAudioSessionPortDescription] { get }
    var preferredInput: AVAudioSessionPortDescription? { get }
    var currentInput: AVAudioSessionPortDescription? { get }
    var currentOutputTypes: [String] { get }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setPreferredSampleRate(_ sampleRate: Double) throws
    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws
    func setPreferredInput(_ input: AVAudioSessionPortDescription?) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
final class SystemAudioSessionController: AudioSessionControlling {
    private let session: AVAudioSession

    init(session: AVAudioSession = AVAudioSession.sharedInstance()) {
        self.session = session
    }

    var category: AVAudioSession.Category { session.category }
    var categoryOptions: AVAudioSession.CategoryOptions { session.categoryOptions }
    var availableInputs: [AVAudioSessionPortDescription] { session.availableInputs ?? [] }
    var preferredInput: AVAudioSessionPortDescription? { session.preferredInput }
    var currentInput: AVAudioSessionPortDescription? { session.currentRoute.inputs.first }
    var currentOutputTypes: [String] {
        session.currentRoute.outputs.map(\.portType.rawValue)
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        try session.setCategory(category, mode: mode, options: options)
    }

    func setPreferredSampleRate(_ sampleRate: Double) throws {
        try session.setPreferredSampleRate(sampleRate)
    }

    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {
        try session.setPreferredIOBufferDuration(duration)
    }

    func setPreferredInput(_ input: AVAudioSessionPortDescription?) throws {
        try session.setPreferredInput(input)
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try session.setActive(active, options: options)
    }
}

/// Enhanced audio session manager for recording, playback, and background operations.
@MainActor
class EnhancedAudioSessionManager: NSObject, ObservableObject {

    // MARK: - Published Properties
    @Published var isConfigured = false
    @Published var isMixedAudioEnabled = false
    @Published var isBackgroundRecordingEnabled = false
    @Published var currentConfiguration: AudioSessionConfig?
    @Published var lastError: AudioProcessingError?

    // MARK: - Private Properties
    private let audioSessionController: any AudioSessionControlling

    // MARK: - Configuration Structures
    struct AudioSessionConfig {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let allowMixedAudio: Bool
        let backgroundRecording: Bool

        static let mixedAudioRecording = AudioSessionConfig(
            category: .playAndRecord,
            mode: .default,  // Use .default instead of .voiceChat to preserve music quality
            options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker],
            allowMixedAudio: true,
            backgroundRecording: false
        )

        static let backgroundRecording = AudioSessionConfig(
            category: .playAndRecord,
            mode: .default,  // Use .default instead of .voiceChat to preserve recording quality
            options: [.allowBluetoothHFP, .defaultToSpeaker],
            allowMixedAudio: false,
            backgroundRecording: true
        )

        static let standardRecording = AudioSessionConfig(
            category: .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP],
            allowMixedAudio: false,
            backgroundRecording: false
        )
    }

    // MARK: - Initialization
    static let shared = EnhancedAudioSessionManager()

    init(audioSessionController: any AudioSessionControlling) {
        self.audioSessionController = audioSessionController
        super.init()
    }

    override convenience init() {
        self.init(audioSessionController: SystemAudioSessionController())
    }

    // MARK: - Public Methods

    /// Configure audio session for mixed audio recording (allows other apps to play audio simultaneously)
    func configureMixedAudioSession() async throws {
        do {
            let config = AudioSessionConfig.mixedAudioRecording
            try await applyConfiguration(config)

            isMixedAudioEnabled = true
            isBackgroundRecordingEnabled = false
            currentConfiguration = config
            isConfigured = true

            AppLog.shared.audioSession("Mixed audio session configured successfully")

            // Prefer Bluetooth HFP if available for recording input
            await autoSelectBestInput()

        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Mixed audio configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }

    /// Configure audio session for active recording.
    /// Recording should interrupt other audio so device playback does not bleed
    /// into the captured note, then deactivation lets other apps resume.
    func configureBackgroundRecording() async throws {
        // First check if background audio permission is available
        guard await checkBackgroundAudioPermission() else {
            let error = AudioProcessingError.backgroundRecordingNotPermitted
            lastError = error
            throw error
        }

        do {
            let config = AudioSessionConfig.backgroundRecording
            try await applyConfiguration(config)

            isMixedAudioEnabled = false
            isBackgroundRecordingEnabled = true
            currentConfiguration = config
            isConfigured = true

            AppLog.shared.audioSession("Exclusive background recording session configured successfully")

            // Prefer Bluetooth HFP if available for recording input
            await autoSelectBestInput()

        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Background recording configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }

    /// Reapply the recording category without activating it.
    ///
    /// Recovery calls this after the old recorder has been stopped and its
    /// segment has been finalized. Keeping preparation separate from activation
    /// lets the recovery coordinator classify the real activation error without
    /// deactivating the session as a retry prelude.
    func prepareBackgroundRecordingForRecovery() async throws {
        guard await checkBackgroundAudioPermission() else {
            let error = AudioProcessingError.backgroundRecordingNotPermitted
            lastError = error
            throw error
        }

        try prepareConfiguration(AudioSessionConfig.backgroundRecording)
    }

    /// Activate the configuration prepared for recording recovery.
    ///
    /// This method intentionally throws the underlying session error unchanged;
    /// the recovery coordinator records its NSError domain and code before it
    /// applies a retry/defer/fail disposition.
    func activatePreparedSession() throws {
        guard currentConfiguration != nil else {
            throw AudioSessionRecoveryError.missingConfiguration
        }

        try audioSessionController.setActive(true, options: [])
        isConfigured = true
    }

    /// Discard manager-side state after iOS reports that media services were
    /// reset. The next recovery attempt reapplies category and preferred I/O
    /// settings before activating; it never deactivates the shared session as
    /// a retry prelude.
    func resetPreparedSessionAfterMediaServicesReset() {
        isConfigured = false
        isMixedAudioEnabled = false
        isBackgroundRecordingEnabled = false
        currentConfiguration = nil
    }

    /// Configure standard recording session (fallback for compatibility)
    func configureStandardRecording() async throws {
        do {
            let config = AudioSessionConfig.standardRecording
            try await applyConfiguration(config)

            isMixedAudioEnabled = false
            isBackgroundRecordingEnabled = false
            currentConfiguration = config
            isConfigured = true

            AppLog.shared.audioSession("Standard recording session configured successfully")

        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Standard recording configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }

    /// Configure audio session for in-app recording playback.
    /// Do not mix with other apps here: recording playback should take over,
    /// then `deactivateSession()` notifies interrupted audio apps to resume.
    func configurePlaybackSession() async throws {
        do {
            try audioSessionController.setCategory(.playback, mode: .default, options: [])
            try audioSessionController.setActive(true, options: [])
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Playback configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
        isMixedAudioEnabled = false
        isBackgroundRecordingEnabled = false
        currentConfiguration = nil
        isConfigured = true
        AppLog.shared.audioSession("Playback session configured for exclusive in-app audio")
    }

    /// Configure audio session for silent background processing keep-alive.
    /// Uses playback instead of playAndRecord so background jobs do not force
    /// microphone/HFP routing that degrades music from other apps.
    func configureBackgroundProcessingSession() async throws {
        guard await checkBackgroundAudioPermission() else {
            let error = AudioProcessingError.backgroundRecordingNotPermitted
            lastError = error
            throw error
        }

        do {
            try audioSessionController.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSessionController.setActive(true, options: [])
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Background processing configuration failed: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
        isMixedAudioEnabled = true
        isBackgroundRecordingEnabled = false
        currentConfiguration = nil
        isConfigured = true
        AppLog.shared.audioSession("Background processing session configured with playback mixWithOthers")
    }

    /// Set preferred audio input device
    func setPreferredInput(_ input: AVAudioSessionPortDescription) async throws {
        do {
            try audioSessionController.setPreferredInput(input)
            AppLog.shared.audioSession("Preferred input set to: \(input.portName) (\(input.portType.rawValue))")
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Failed to set preferred input: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }

    /// Clear the preferred input to let iOS use its default microphone
    func clearPreferredInput() async throws {
        do {
            try audioSessionController.setPreferredInput(nil)
            AppLog.shared.audioSession("Preferred input cleared, iOS will use default microphone")
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Failed to clear preferred input: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
    }

    /// Get available audio inputs
    func getAvailableInputs() -> [AVAudioSessionPortDescription] {
        return audioSessionController.availableInputs
    }

    /// Get the currently active or preferred input
    func getActiveInput() -> AVAudioSessionPortDescription? {
        if let preferredInput = audioSessionController.preferredInput {
            return preferredInput
        }

        return audioSessionController.currentInput
    }

    /// Returns route types for recovery diagnostics without exposing the
    /// concrete AVAudioSession controller to recording policy code.
    func currentOutputTypesForDiagnostics() -> [String] {
        audioSessionController.currentOutputTypes
    }

    /// Check if mixed audio recording is currently supported
    func isMixedAudioSupported() -> Bool {
        return audioSessionController.category == .playAndRecord &&
               audioSessionController.categoryOptions.contains(.mixWithOthers)
    }

    /// Deactivate audio session
    func deactivateSession() async throws {
        do {
            try audioSessionController.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            let audioError = AudioProcessingError.audioSessionConfigurationFailed("Failed to deactivate session: \(error.localizedDescription)")
            lastError = audioError
            throw audioError
        }
        isConfigured = false
        isMixedAudioEnabled = false
        isBackgroundRecordingEnabled = false
        currentConfiguration = nil
        AppLog.shared.audioSession("Audio session deactivated and reset")
    }

    // MARK: - Private Methods

    private func applyConfiguration(_ config: AudioSessionConfig) async throws {
        try prepareConfiguration(config)
        try activatePreparedSession()

        if config.backgroundRecording {
            try await requestBackgroundAudioCapability()
        }
    }

    private func prepareConfiguration(_ config: AudioSessionConfig) throws {
        try audioSessionController.setCategory(config.category, mode: config.mode, options: config.options)

        if config.category == .playAndRecord {
            try? audioSessionController.setPreferredSampleRate(16000)
            try? audioSessionController.setPreferredIOBufferDuration(0.1)
        }

        currentConfiguration = config
        isMixedAudioEnabled = config.allowMixedAudio
        isBackgroundRecordingEnabled = config.backgroundRecording
    }

    private func checkBackgroundAudioPermission() async -> Bool {
        // Check if the app has background audio capability in Info.plist
        guard let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
              backgroundModes.contains("audio") else {
            AppLog.shared.audioSession("Background audio mode not configured in Info.plist", level: .error)
            return false
        }

        return true
    }

    private func requestBackgroundAudioCapability() async throws {
        // This would typically involve requesting background app refresh permission
        // For now, we'll just verify the configuration is correct
        guard audioSessionController.category == .playAndRecord else {
            throw AudioProcessingError.backgroundRecordingNotPermitted
        }
    }

    // MARK: - Input Selection

    /// Selects Bluetooth HFP input if available, otherwise falls back to built-in mic
    @MainActor
    private func autoSelectBestInput() async {
        let inputs = audioSessionController.availableInputs
        if let bluetoothHFP = inputs.first(where: { $0.portType == .bluetoothHFP }) {
            do { try audioSessionController.setPreferredInput(bluetoothHFP) } catch { /* best-effort */ }
            return
        }
        if let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
            do { try audioSessionController.setPreferredInput(builtInMic) } catch { /* best-effort */ }
        }
    }
}

#else

// AVAudioSession does not exist on native macOS. AVAudioEngine records without
// a session, while input discovery and selection use AVCaptureDevice + Core Audio.

/// Minimal stand-in for AVAudioSessionPortDescription so the shared audio stack
/// compiles on native macOS. Callers only use portName, uid, and portType.
final class AVAudioSessionPortDescription: NSObject {
    struct Port: Equatable {
        let rawValue: String
        static let builtInMic = Port(rawValue: "BuiltInMic")
        static let bluetoothHFP = Port(rawValue: "BluetoothHFP")
        static let headsetMic = Port(rawValue: "HeadsetMic")
        static let usbAudio = Port(rawValue: "USBAudio")
    }

    let portName: String
    let uid: String
    let portType: Port
    let audioDeviceID: AudioDeviceID

    init(portName: String, uid: String, portType: Port, audioDeviceID: AudioDeviceID) {
        self.portName = portName
        self.uid = uid
        self.portType = portType
        self.audioDeviceID = audioDeviceID
    }
}

@MainActor
class EnhancedAudioSessionManager: NSObject, ObservableObject {
    static let shared = EnhancedAudioSessionManager()

    @Published var isConfigured = false
    @Published var isMixedAudioEnabled = false
    @Published var isBackgroundRecordingEnabled = false
    @Published var lastError: AudioProcessingError?

    private var preferredInputDeviceID: AudioDeviceID?
    private var configuredInputDeviceID: AudioDeviceID?
    private var inputDeviceMonitor: MacInputDeviceMonitor?

    deinit {
        // MacInputDeviceMonitor removes its Core Audio listeners from its own
        // deinitializer; the main-actor manager cannot call into it here.
    }

    func configureMixedAudioSession() async throws {
        isConfigured = true
        isMixedAudioEnabled = true
        isBackgroundRecordingEnabled = false
    }

    func configureBackgroundRecording() async throws {
        isConfigured = true
        isMixedAudioEnabled = false
        isBackgroundRecordingEnabled = true
    }

    func configurePlaybackSession() async throws {
        isConfigured = true
        isMixedAudioEnabled = false
        isBackgroundRecordingEnabled = false
    }

    func configureBackgroundProcessingSession() async throws {
        isConfigured = true
        isMixedAudioEnabled = true
        isBackgroundRecordingEnabled = false
    }

    func deactivateSession() async throws {
        isConfigured = false
        isMixedAudioEnabled = false
        isBackgroundRecordingEnabled = false
    }

    func setPreferredInput(_ input: AVAudioSessionPortDescription) async throws {
        guard getAvailableInputs().contains(where: { $0.audioDeviceID == input.audioDeviceID }) else {
            let error = AudioProcessingError.audioSessionConfigurationFailed(
                "The selected microphone is no longer available."
            )
            lastError = error
            throw error
        }

        preferredInputDeviceID = input.audioDeviceID
        AppLog.shared.audioSession("Preferred Mac input set to: \(input.portName) (\(input.uid))")
    }

    func clearPreferredInput() async throws {
        preferredInputDeviceID = nil
        AppLog.shared.audioSession("Preferred Mac input cleared; using the system default microphone")
    }

    /// True when a recording would be explicitly bound to a user-selected
    /// input rather than the current macOS default. Startup recovery can use
    /// this to try the default route after a selected USB device produces no
    /// input buffers, without forgetting the persisted user preference.
    func hasPreferredInput() -> Bool {
        preferredInputDeviceID != nil
    }

    func getAvailableInputs() -> [AVAudioSessionPortDescription] {
        let defaultDeviceID = Self.defaultInputDeviceID()
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        var seenDeviceIDs = Set<AudioDeviceID>()
        let inputs = discoverySession.devices.compactMap { device -> AVAudioSessionPortDescription? in
            guard let deviceID = Self.audioDeviceID(forUID: device.uniqueID),
                  seenDeviceIDs.insert(deviceID).inserted else {
                return nil
            }

            return AVAudioSessionPortDescription(
                portName: device.localizedName,
                uid: device.uniqueID,
                portType: Self.portType(for: deviceID),
                audioDeviceID: deviceID
            )
        }

        return inputs.sorted { lhs, rhs in
            if lhs.audioDeviceID == defaultDeviceID { return true }
            if rhs.audioDeviceID == defaultDeviceID { return false }
            return lhs.portName.localizedCaseInsensitiveCompare(rhs.portName) == .orderedAscending
        }
    }

    func getActiveInput() -> AVAudioSessionPortDescription? {
        let inputs = getAvailableInputs()
        if let preferredInputDeviceID,
           let preferredInput = inputs.first(where: { $0.audioDeviceID == preferredInputDeviceID }) {
            return preferredInput
        }

        guard let defaultDeviceID = Self.defaultInputDeviceID() else {
            return inputs.first
        }
        return inputs.first(where: { $0.audioDeviceID == defaultDeviceID }) ?? inputs.first
    }

    /// The device a newly created recording engine should use. A disconnected
    /// preferred device automatically falls back to the current system default.
    func resolvedInputDeviceID() -> AudioDeviceID? {
        let availableDeviceIDs = Set(getAvailableInputs().map(\.audioDeviceID))
        if let preferredInputDeviceID, availableDeviceIDs.contains(preferredInputDeviceID) {
            return preferredInputDeviceID
        }
        return Self.defaultInputDeviceID()
    }

    /// True when the engine is still bound to the device the current preference
    /// resolves to. Device-list and default-input listeners use this to ignore
    /// unrelated audio-device changes.
    func recordingInputNeedsRecovery() -> Bool {
        guard let configuredInputDeviceID else { return false }
        return configuredInputDeviceID != resolvedInputDeviceID()
    }

    func clearConfiguredInputDevice() {
        configuredInputDeviceID = nil
    }

    /// Watches both the system default input and the complete Core Audio device
    /// list. The latter is required for a selected non-default USB/Bluetooth mic.
    func startInputDeviceMonitoring(onChange: @escaping @MainActor @Sendable () -> Void) {
        stopInputDeviceMonitoring()
        let monitor = MacInputDeviceMonitor(onChange: onChange)
        monitor.start()
        inputDeviceMonitor = monitor
    }

    func stopInputDeviceMonitoring() {
        inputDeviceMonitor?.stop()
        inputDeviceMonitor = nil
    }

    /// Applies the selected Mac input to this engine without changing the
    /// user's system-wide default input device.
    func configureInputDevice(for engine: AVAudioEngine) throws {
        guard let deviceID = resolvedInputDeviceID() else {
            let error = AudioProcessingError.audioSessionConfigurationFailed("No microphone is available.")
            lastError = error
            throw error
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            let error = AudioProcessingError.audioSessionConfigurationFailed(
                "The microphone audio unit could not be created."
            )
            lastError = error
            throw error
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            let systemError = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            let error = AudioProcessingError.audioSessionConfigurationFailed(
                "Failed to select the microphone: \(systemError.localizedDescription)"
            )
            lastError = error
            throw error
        }
        configuredInputDeviceID = deviceID

        let inputName = getAvailableInputs()
            .first(where: { $0.audioDeviceID == deviceID })?
            .portName ?? "system default"
        AppLog.shared.audioSession("Configured AVAudioEngine input: \(inputName)")
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func audioDeviceID(forUID value: String) -> AudioDeviceID? {
        var uid = value as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status: OSStatus = withUnsafeMutablePointer(to: &uid) { uidPointer in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(deviceIDPointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func portType(for deviceID: AudioDeviceID) -> AVAudioSessionPortDescription.Port {
        var transportType: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return .headsetMic }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtInMic
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothHFP
        case kAudioDeviceTransportTypeUSB:
            return .usbAudio
        default:
            return .headsetMic
        }
    }

}

#endif

// MARK: - Error Types

enum AudioProcessingError: Error, LocalizedError {
    case audioSessionConfigurationFailed(String)
    case backgroundRecordingNotPermitted
    case chunkingFailed(String)
    case iCloudSyncFailed(String)
    case backgroundProcessingFailed(String)
    case fileRelationshipError(String)
    case recordingFailed(String)
    case playbackFailed(String)
    case formatConversionFailed(String)
    case metadataExtractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioSessionConfigurationFailed(let message):
            return "Audio session configuration failed: \(message)"
        case .backgroundRecordingNotPermitted:
            return "Background recording permission not granted. Please enable background audio in app settings."
        case .chunkingFailed(let message):
            return "Audio file chunking failed: \(message)"
        case .iCloudSyncFailed(let message):
            return "iCloud synchronization failed: \(message)"
        case .backgroundProcessingFailed(let message):
            return "Background processing failed: \(message)"
        case .fileRelationshipError(let message):
            return "File relationship error: \(message)"
        case .recordingFailed(let message):
            return "Audio recording failed: \(message)"
        case .playbackFailed(let message):
            return "Audio playback failed: \(message)"
        case .formatConversionFailed(let message):
            return "Audio format conversion failed: \(message)"
        case .metadataExtractionFailed(let message):
            return "Audio metadata extraction failed: \(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .audioSessionConfigurationFailed:
            return "Try restarting the app or check your device's audio settings."
        case .backgroundRecordingNotPermitted:
            return "Enable background app refresh for this app in Settings > General > Background App Refresh."
        case .chunkingFailed:
            return "Try recording a shorter audio file or check available storage space."
        case .iCloudSyncFailed:
            return "Check your internet connection and iCloud settings."
        case .backgroundProcessingFailed:
            return "Try processing the file again when the app is in the foreground."
        case .fileRelationshipError:
            return "Try refreshing the file list or restarting the app."
        case .recordingFailed:
            return "Check microphone permissions and try recording again."
        case .playbackFailed:
            return "Check audio output settings and try playing again."
        case .formatConversionFailed:
            return "Try a different audio format or check file integrity."
        case .metadataExtractionFailed:
            return "Try refreshing the file or check if the file is corrupted."
        }
    }
}
