
import Foundation
import UIKit

struct DeviceCompatibility {

    // MARK: - WhisperKit Support

    /// Cached result for WhisperKit support check
    private static var _cachedWhisperKitSupport: Bool?
    private static var _hasLoggedWhisperKitSupport = false

    /// Check if device supports WhisperKit on-device transcription
    /// Requires iOS 17+ and 4GB+ RAM for the large-v3-turbo model
    static var isWhisperKitSupported: Bool {
        // Return cached value if available
        if let cached = _cachedWhisperKitSupport {
            return cached
        }

        // Check iOS version (iOS 17+)
        guard #available(iOS 17.0, *) else {
            if !_hasLoggedWhisperKitSupport {
                print("❌ DeviceCompatibility: iOS 17+ required for WhisperKit")
                _hasLoggedWhisperKitSupport = true
            }
            _cachedWhisperKitSupport = false
            return false
        }

        // Check RAM (4GB minimum)
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let totalMemoryGB = Double(totalMemory) / 1_073_741_824.0
        let hasEnoughRAM = totalMemoryGB >= 4.0

        // Only log once
        if !_hasLoggedWhisperKitSupport {
            if hasEnoughRAM {
                print("✅ DeviceCompatibility: WhisperKit supported (RAM: \(String(format: "%.1f", totalMemoryGB))GB)")
            } else {
                print("❌ DeviceCompatibility: WhisperKit requires 4GB+ RAM (Device has \(String(format: "%.1f", totalMemoryGB))GB)")
            }
            _hasLoggedWhisperKitSupport = true
        }

        _cachedWhisperKitSupport = hasEnoughRAM
        return hasEnoughRAM
    }

    // MARK: - Native Speech Recognition Support

    /// Check if device supports native speech recognition transcription (3GB+ RAM, iOS 18.1+)
    static var isNativeSpeechTranscriptionSupported: Bool {
        guard isCorrectOSVersionForTranscription else {
            return false
        }

        #if targetEnvironment(simulator)
        print("✅ DeviceCompatibility: Simulator detected - enabling native speech transcription support")
        return true
        #else
        // Check RAM (3GB minimum)
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let totalMemoryGB = Double(totalMemory) / 1_073_741_824.0
        let hasEnoughRAM = totalMemoryGB >= 3.0

        if hasEnoughRAM {
            print("✅ DeviceCompatibility: Native speech transcription supported (RAM: \(String(format: "%.1f", totalMemoryGB))GB)")
            return true
        } else {
            print("❌ DeviceCompatibility: Native speech transcription requires 3GB+ RAM (Device has \(String(format: "%.1f", totalMemoryGB))GB)")
            return false
        }
        #endif
    }

    private static var isCorrectOSVersionForTranscription: Bool {
        // Native speech transcription requires iOS 18.1+ for full functionality
        if #available(iOS 18.1, *) {
            print("✅ DeviceCompatibility: iOS 18.1+ detected - transcription support")
            return true
        }

        print("❌ DeviceCompatibility: iOS 18.1+ required for native speech transcription")
        return false
    }

    // MARK: - On-Device AI Support

    /// Check if device supports on-device AI (summarization)
    /// Requires 6GB+ RAM (uses DeviceCapabilities for consistency)
    static var isOnDeviceAISupported: Bool {
        return DeviceCapabilities.supportsOnDeviceLLM
    }
}

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
