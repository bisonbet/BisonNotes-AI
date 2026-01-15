//
//  DeviceCapabilities.swift
//  BisonNotes AI
//
//  Utility to check device capabilities for feature availability
//

import Foundation
import UIKit

struct DeviceCapabilities {

    /// Returns the total physical RAM in gigabytes
    static var totalRAMInGB: Double {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let gigabytes = Double(physicalMemory) / 1_073_741_824.0 // Convert bytes to GB
        return gigabytes
    }

    /// Returns the total physical RAM in bytes
    static var totalRAMInBytes: UInt64 {
        return ProcessInfo.processInfo.physicalMemory
    }

    /// Check if device has sufficient RAM for on-device LLM processing
    /// Requires at least 6GB of RAM for reliable operation
    /// For devices with <6GB RAM, returns true only if experimental models are enabled
    static var supportsOnDeviceLLM: Bool {
        let minimumRAM: Double = 6.0 // 6GB minimum for reliable operation
        let deviceRAM = totalRAMInGB

        // Devices with 6GB+ RAM always support on-device LLM
        if deviceRAM >= minimumRAM {
            return true
        }
        
        // Devices with <6GB RAM only support on-device LLM if experimental models are enabled
        let experimentalEnabled = UserDefaults.standard.bool(forKey: "onDeviceLLMEnableExperimentalModels")
        return experimentalEnabled
    }

    /// Check if device has sufficient RAM for basic Whisper models
    /// Requires at least 4GB of RAM for base/medium models
    static var supportsWhisperBasic: Bool {
        let minimumRAM: Double = 4.0 // 4GB minimum for small models
        let deviceRAM = totalRAMInGB


        return deviceRAM >= minimumRAM
    }

    /// Check if device has sufficient RAM for large Whisper models
    /// Requires at least 6GB of RAM
    static var supportsWhisperLarge: Bool {
        let minimumRAM: Double = 6.0 // 6GB minimum for large models
        let deviceRAM = totalRAMInGB


        return deviceRAM >= minimumRAM
    }

    /// Check if device has sufficient RAM for 8GB models (Qwen 3 8B)
    /// Requires at least 8GB of RAM
    static var supports8GBModels: Bool {
        let minimumRAM: Double = 8.0 // 8GB minimum for larger models
        let deviceRAM = totalRAMInGB


        return deviceRAM >= minimumRAM
    }

    /// Get the appropriate context size for on-device LLM based on device RAM
    /// - Returns: 8192 tokens for devices with <8GB RAM, 16384 tokens for devices with >=8GB RAM
    static var onDeviceLLMContextSize: Int {
        let deviceRAM = totalRAMInGB
        return deviceRAM < 8.0 ? 8192 : 16384
    }

    /// Get a human-readable RAM description
    static var ramDescription: String {
        let ram = totalRAMInGB
        return String(format: "%.1f GB", ram)
    }

    /// Get device model name
    static var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    /// Get a detailed capability report
    static func getCapabilityReport() -> String {
        var report = "Device Capabilities Report\n"
        report += "==========================\n"
        report += "Model: \(modelName)\n"
        report += "RAM: \(ramDescription)\n"
        report += "On-Device LLM Support: \(supportsOnDeviceLLM ? "✅" : "❌")\n"

        if #available(iOS 16.0, *) {
            report += "iOS Version: ✅ (16.0+)\n"
        } else {
            report += "iOS Version: ❌ (< 16.0)\n"
        }

        return report
    }
}
