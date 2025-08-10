
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
        
        // iPhone 15 Pro and iPhone 15 Pro Max: iPhone16,1 and iPhone16,2
        // iPhone 16 series: iPhone17,1 - iPhone17,4 (and future models)
        let supportedModels = [
            "iPhone16,1", // iPhone 15 Pro
            "iPhone16,2", // iPhone 15 Pro Max
            "iPhone17,1", // iPhone 16 (expected)
            "iPhone17,2", // iPhone 16 Plus (expected)
            "iPhone17,3", // iPhone 16 Pro (expected)
            "iPhone17,4", // iPhone 16 Pro Max (expected)
        ]
        
        // Also support any iPhone17,x or higher for future models
        if modelCode.hasPrefix("iPhone17,") || modelCode.hasPrefix("iPhone18,") || modelCode.hasPrefix("iPhone19,") {
            print("✅ DeviceCompatibility: Future iPhone model supported")
            return true
        }
        
        let isSupported = supportedModels.contains(modelCode)
        print("✅ DeviceCompatibility: \(modelCode) supported: \(isSupported)")
        return isSupported
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
