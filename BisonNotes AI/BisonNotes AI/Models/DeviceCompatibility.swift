
import Foundation
import UIKit

struct DeviceCompatibility {

    static var isAppleIntelligenceSupported: Bool {
        return isCorrectOSVersion && isCompatibleDevice
    }

    private static var isCorrectOSVersion: Bool {
        // Apple Intelligence requires iOS 18.1+ for full functionality
        // This ensures both transcription and summarization work properly
        if #available(iOS 18.1, *) {
            print("✅ DeviceCompatibility: iOS 18.1+ detected - full Apple Intelligence support")
            return true
        }
        
        print("❌ DeviceCompatibility: iOS 18.1+ required for Apple Intelligence")
        return false
    }

    private static var isCompatibleDevice: Bool {
        let modelCode = UIDevice.current.modelName
        print("🔍 DeviceCompatibility checking model: \(modelCode)")

        // Enable Apple Intelligence for all simulators since we assume they're running on supported hardware
        #if targetEnvironment(simulator)
        print("✅ DeviceCompatibility: Simulator detected - enabling Apple Intelligence support")
        return true
        #else

        // iPhone models with Apple Intelligence support
        let supportediPhoneModels = [
            "iPhone16,1", // iPhone 15 Pro
            "iPhone16,2", // iPhone 15 Pro Max
            "iPhone17,1", // iPhone 16 (expected)
            "iPhone17,2", // iPhone 16 Plus (expected)
            "iPhone17,3", // iPhone 16 Pro (expected)
            "iPhone17,4", // iPhone 16 Pro Max (expected)
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

        let allSupportedModels = supportediPhoneModels + supportediPadProModels + supportediPadAirModels + supportediPadMiniModels

        // Also support any iPhone17,x or higher for future iPhone models
        if modelCode.hasPrefix("iPhone17,") || modelCode.hasPrefix("iPhone18,") || modelCode.hasPrefix("iPhone19,") {
            print("✅ DeviceCompatibility: Future iPhone model supported")
            return true
        }

        // Support future iPad models with advanced chips
        if modelCode.hasPrefix("iPad16,") || modelCode.hasPrefix("iPad17,") || modelCode.hasPrefix("iPad18,") {
            print("✅ DeviceCompatibility: Future iPad model supported")
            return true
        }

        let isSupported = allSupportedModels.contains(modelCode)
        print("✅ DeviceCompatibility: \(modelCode) supported: \(isSupported)")
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
