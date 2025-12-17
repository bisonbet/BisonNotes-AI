//
//  DeviceCapabilities.swift
//  BisonNotes AI
//
//  Utility to check device capabilities for feature availability
//

import Foundation
import UIKit
import Metal

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
    /// Requires at least 6GB of RAM for full LLM models
    static var supportsOnDeviceLLM: Bool {
        let minimumRAM: Double = 6.0 // 6GB minimum
        let deviceRAM = totalRAMInGB

        print("🔍 DeviceCapabilities: Device has \(String(format: "%.2f", deviceRAM))GB RAM")
        print("🔍 DeviceCapabilities: On-device LLM support: \(deviceRAM >= minimumRAM)")

        return deviceRAM >= minimumRAM
    }

    /// Check if device has sufficient RAM for basic Whisper models
    /// Requires at least 4GB of RAM for base/medium models
    static var supportsWhisperBasic: Bool {
        let minimumRAM: Double = 4.0 // 4GB minimum for small models
        let deviceRAM = totalRAMInGB

        print("🔍 DeviceCapabilities: Whisper basic support (4GB+): \(deviceRAM >= minimumRAM)")

        return deviceRAM >= minimumRAM
    }

    /// Check if device has sufficient RAM for large Whisper models
    /// Requires at least 6GB of RAM
    static var supportsWhisperLarge: Bool {
        let minimumRAM: Double = 6.0 // 6GB minimum for large models
        let deviceRAM = totalRAMInGB

        print("🔍 DeviceCapabilities: Whisper large support (6GB+): \(deviceRAM >= minimumRAM)")

        return deviceRAM >= minimumRAM
    }

    /// Check if device has sufficient RAM for 8GB models (Qwen 3 8B)
    /// Requires at least 8GB of RAM
    static var supports8GBModels: Bool {
        let minimumRAM: Double = 8.0 // 8GB minimum for larger models
        let deviceRAM = totalRAMInGB

        print("🔍 DeviceCapabilities: 8GB model support (8GB+): \(deviceRAM >= minimumRAM)")

        return deviceRAM >= minimumRAM
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

    /// Check if device supports Metal Performance Shaders (required for MLX)
    static var supportsMetalPerformanceShaders: Bool {
        #if targetEnvironment(simulator)
        // Simulators may not have full Metal support
        return false
        #else
        // Check for Metal device availability
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }

        // Check if device supports iOS 16+ (MLX requirement)
        if #available(iOS 16.0, *) {
            return device.supportsFamily(.apple7) || device.supportsFamily(.apple8) || device.supportsFamily(.apple9)
        }

        return false
        #endif
    }

    /// Comprehensive check for MLX support
    static var supportsMLX: Bool {
        // Check RAM requirement
        guard supportsOnDeviceLLM else {
            print("⚠️ DeviceCapabilities: Insufficient RAM for MLX")
            return false
        }

        // Check Metal support
        guard supportsMetalPerformanceShaders else {
            print("⚠️ DeviceCapabilities: Metal Performance Shaders not supported")
            return false
        }

        // Check iOS version
        if #available(iOS 16.0, *) {
            print("✅ DeviceCapabilities: Device supports MLX")
            return true
        } else {
            print("⚠️ DeviceCapabilities: iOS version too old for MLX")
            return false
        }
    }

    /// Get a detailed capability report
    static func getCapabilityReport() -> String {
        var report = "Device Capabilities Report\n"
        report += "==========================\n"
        report += "Model: \(modelName)\n"
        report += "RAM: \(ramDescription)\n"
        report += "On-Device LLM Support: \(supportsOnDeviceLLM ? "✅" : "❌")\n"
        report += "Metal Performance Shaders: \(supportsMetalPerformanceShaders ? "✅" : "❌")\n"
        report += "MLX Support: \(supportsMLX ? "✅" : "❌")\n"

        if #available(iOS 16.0, *) {
            report += "iOS Version: ✅ (16.0+)\n"
        } else {
            report += "iOS Version: ❌ (< 16.0)\n"
        }

        return report
    }
}
