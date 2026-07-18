//
//  DeviceCapabilities.swift
//  BisonNotes AI
//
//  Utility to check device capabilities for feature availability
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    /// Legacy On-Device AI (llama) requires at least 6GB of RAM. No experimental
    /// override — devices under 6GB were unreliable in practice and are off the
    /// legacy path entirely.
    static var supportsOnDeviceLLM: Bool {
        return totalRAMInGB >= 6.0
    }

    /// MLX-based on-device AI supports devices down to 4GB by way of the small
    /// 1.7B model. 6GB+ devices get the 4B/8B options; 4-6GB devices are
    /// limited to the 1.7B model.
    static var supportsMLX: Bool {
        return totalRAMInGB >= 4.0
    }

    /// Action Button is only available on supported iPhone hardware. Apple
    /// does not expose a direct capability API, so gate the setup guidance by
    /// known device identifier families and keep Mac Catalyst/iPad hidden.
    static var supportsActionButton: Bool {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return false
        #else
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return false
        }

        let components = modelName
            .replacingOccurrences(of: "iPhone", with: "")
            .split(separator: ",")
            .compactMap { Int($0) }

        guard components.count == 2 else {
            return false
        }

        let major = components[0]
        let minor = components[1]

        // iPhone16,1 and iPhone16,2 are iPhone 15 Pro / Pro Max, the first
        // iPhones with Action Button. Later iPhone identifier families include
        // Action Button across the currently supported lineup.
        return major > 16 || (major == 16 && (minor == 1 || minor == 2))
        #endif
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
        report += "Action Button Support: \(supportsActionButton ? "✅" : "❌")\n"

        if #available(iOS 16.0, *) {
            report += "iOS Version: ✅ (16.0+)\n"
        } else {
            report += "iOS Version: ❌ (< 16.0)\n"
        }

        return report
    }
}
