import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct DeviceCompatibility {

    // MARK: - Native Speech Recognition Support

    /// Check if device supports native speech recognition transcription (3GB+ RAM, iOS 18.1+)
    static var isNativeSpeechTranscriptionSupported: Bool {
        guard isCorrectOSVersionForTranscription else {
            return false
        }

        #if targetEnvironment(simulator)
        AppLog.shared.performance("DeviceCompatibility: Simulator detected - enabling native speech transcription support")
        return true
        #else
        // Check RAM (3GB minimum)
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let totalMemoryGB = Double(totalMemory) / 1_073_741_824.0
        let hasEnoughRAM = totalMemoryGB >= 3.0

        if hasEnoughRAM {
            AppLog.shared.performance("DeviceCompatibility: Native speech transcription supported (RAM: \(String(format: "%.1f", totalMemoryGB))GB)")
            return true
        } else {
            AppLog.shared.performance("DeviceCompatibility: Native speech transcription requires 3GB+ RAM (Device has \(String(format: "%.1f", totalMemoryGB))GB)")
            return false
        }
        #endif
    }

    private static var isCorrectOSVersionForTranscription: Bool {
        // Native speech transcription requires iOS 18.1+ for full functionality
        if #available(iOS 18.1, *) {
            AppLog.shared.performance("DeviceCompatibility: iOS 18.1+ detected - transcription support")
            return true
        }

        AppLog.shared.performance("DeviceCompatibility: iOS 18.1+ required for native speech transcription")
        return false
    }

    // MARK: - On-Device AI Support

    /// Check if device supports on-device AI (summarization)
    /// Requires 4GB+ RAM for the MLX 1.7B model (uses DeviceCapabilities for consistency)
    static var isOnDeviceAISupported: Bool {
        return DeviceCapabilities.supportsMLX
    }

    // MARK: - FluidAudio Support

    /// The support check is evaluated once by Swift's thread-safe lazy static
    /// initialization. Keeping the cached value immutable avoids unsynchronized
    /// global mutation while preserving the existing one-time log behavior.
    private static let fluidAudioSupport = calculateFluidAudioSupport()

    /// FluidAudio requires iOS 17+ and 4GB+ RAM for CoreML/ANE model inference
    static var isFluidAudioSupported: Bool {
        fluidAudioSupport
    }

    private static func calculateFluidAudioSupport() -> Bool {
        guard #available(iOS 17.0, *) else {
            AppLog.shared.performance("DeviceCompatibility: iOS 17+ required for FluidAudio")
            return false
        }

        // Check RAM (4GB minimum for CoreML ANE inference)
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let totalMemoryGB = Double(totalMemory) / 1_073_741_824.0
        let hasEnoughRAM = totalMemoryGB >= 4.0

        if hasEnoughRAM {
            AppLog.shared.performance("DeviceCompatibility: FluidAudio supported (RAM: \(String(format: "%.1f", totalMemoryGB))GB)")
        } else {
            AppLog.shared.performance("DeviceCompatibility: FluidAudio requires 4GB+ RAM (Device has \(String(format: "%.1f", totalMemoryGB))GB)")
        }

        return hasEnoughRAM
    }
}

#if canImport(UIKit)
public extension UIDevice {
    var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}
#endif
