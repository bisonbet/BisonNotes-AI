
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

    // MARK: - Apple Intelligence Support

    /// Check if device supports Apple Intelligence transcription (iPhone 12 or newer, iOS 18.1+)
    static var isAppleIntelligenceTranscriptionSupported: Bool {
        guard isCorrectOSVersionForTranscription else {
            return false
        }
        
        #if targetEnvironment(simulator)
        print("✅ DeviceCompatibility: Simulator detected - enabling Apple Intelligence transcription support")
        return true
        #else
        let modelCode = UIDevice.current.modelName
        print("🔍 DeviceCompatibility checking model for transcription: \(modelCode)")
        
        // iPhone 12 or newer (iPhone13,x and above) - automatically supports future models
        if modelCode.hasPrefix("iPhone13,") || modelCode.hasPrefix("iPhone14,") || 
           modelCode.hasPrefix("iPhone15,") || modelCode.hasPrefix("iPhone16,") ||
           modelCode.hasPrefix("iPhone17,") || modelCode.hasPrefix("iPhone18,") || 
           modelCode.hasPrefix("iPhone19,") {
            print("✅ DeviceCompatibility: iPhone 12+ detected - transcription supported")
            return true
        }
        
        print("❌ DeviceCompatibility: iPhone 12+ required for Apple Intelligence transcription")
        return false
        #endif
    }
    
    private static var isCorrectOSVersionForTranscription: Bool {
        // Apple Intelligence transcription requires iOS 18.1+ for full functionality
        if #available(iOS 18.1, *) {
            print("✅ DeviceCompatibility: iOS 18.1+ detected - transcription support")
            return true
        }
        
        print("❌ DeviceCompatibility: iOS 18.1+ required for Apple Intelligence transcription")
        return false
    }

    /// Check if device supports Apple Intelligence on-device AI (summarization)
    /// Requires iPhone 15 Pro or newer, or iPhone 16 or newer
    static var isAppleIntelligenceSupported: Bool {
        return isCorrectOSVersion && isCompatibleDeviceForOnDeviceAI
    }

    private static var isCorrectOSVersion: Bool {
        // Apple Intelligence on-device AI requires iOS 18.1+ for full functionality
        if #available(iOS 18.1, *) {
            print("✅ DeviceCompatibility: iOS 18.1+ detected - on-device AI support")
            return true
        }
        
        print("❌ DeviceCompatibility: iOS 18.1+ required for on-device AI")
        return false
    }

    private static var isCompatibleDeviceForOnDeviceAI: Bool {
        let modelCode = UIDevice.current.modelName
        print("🔍 DeviceCompatibility checking model for on-device AI: \(modelCode)")

        // Enable for all simulators since we assume they're running on supported hardware
        #if targetEnvironment(simulator)
        print("✅ DeviceCompatibility: Simulator detected - enabling on-device AI support")
        return true
        #else

        // iPhone 15 Pro series
        let supportediPhone15ProModels = [
            "iPhone16,1", // iPhone 15 Pro
            "iPhone16,2", // iPhone 15 Pro Max
        ]

        // iPhone 16 series (all models)
        let supportediPhone16Models = [
            "iPhone17,1", // iPhone 16
            "iPhone17,2", // iPhone 16 Plus
            "iPhone17,3", // iPhone 16 Pro
            "iPhone17,4", // iPhone 16 Pro Max
        ]

        // iPad Pro models with Apple Intelligence support
        let supportediPadProModels = [
            // iPad Pro 11-inch models (3rd generation M1 2021 and later)
            "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7", // 11-inch (3rd gen, M1, 2021)
            "iPad14,3", "iPad14,4", // 11-inch (4th gen, M2, 2022)
            "iPad16,3", "iPad16,4", // 11-inch (M4, 2024)

            // iPad Pro 12.9-inch models (5th generation M1 2021 and later)
            "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11", // 12.9-inch (5th gen, M1, 2021)
            "iPad14,5", "iPad14,6", // 12.9-inch (6th gen, M2, 2022)

            // iPad Pro 13-inch models (M4, 2024)
            "iPad16,5", "iPad16,6", // 13-inch (M4, 2024)
        ]

        // iPad Air models with Apple Intelligence support
        let supportediPadAirModels = [
            // iPad Air 5th generation (M1, 2022) and later
            "iPad13,16", "iPad13,17", // iPad Air (5th gen, M1, 2022)

            // iPad Air 6th generation (11-inch and 13-inch, M2, 2024)
            "iPad14,8", "iPad14,9",   // iPad Air 11-inch (6th gen, M2, 2024)
            "iPad14,10", "iPad14,11", // iPad Air 13-inch (6th gen, M2, 2024)
        ]

        // iPad mini models with Apple Intelligence support
        let supportediPadMiniModels = [
            // iPad mini 7th generation (A17 Pro, 2024) and later
            "iPad16,1", "iPad16,2", // iPad mini (7th gen, A17 Pro, 2024)
        ]

        let allSupportedModels = supportediPhone15ProModels + supportediPhone16Models + 
                                 supportediPadProModels + supportediPadAirModels + supportediPadMiniModels

        // Support iPhone 15 Pro (iPhone16,1/2) or iPhone 16 series (iPhone17,x) or future iPhone models
        if modelCode.hasPrefix("iPhone16,") || modelCode.hasPrefix("iPhone17,") || 
           modelCode.hasPrefix("iPhone18,") || modelCode.hasPrefix("iPhone19,") {
            // Check if it's iPhone 15 Pro (16,1 or 16,2) or iPhone 16+ (17,x and above)
            if modelCode.hasPrefix("iPhone16,") {
                // Only iPhone 15 Pro models (16,1 and 16,2)
                if modelCode == "iPhone16,1" || modelCode == "iPhone16,2" {
                    print("✅ DeviceCompatibility: iPhone 15 Pro detected - on-device AI supported")
                    return true
                }
            } else {
                // iPhone 16 or newer (all models)
                print("✅ DeviceCompatibility: iPhone 16+ detected - on-device AI supported")
                return true
            }
        }

        // Support future iPad models with advanced chips
        if modelCode.hasPrefix("iPad16,") || modelCode.hasPrefix("iPad17,") || modelCode.hasPrefix("iPad18,") {
            print("✅ DeviceCompatibility: Future iPad model supported for on-device AI")
            return true
        }

        let isSupported = allSupportedModels.contains(modelCode)
        print("✅ DeviceCompatibility: \(modelCode) on-device AI supported: \(isSupported)")
        return isSupported
        #endif
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
