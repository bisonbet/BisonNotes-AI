//
//  DeviceCapability.swift
//  BisonNotes AI
//
//  Device capability detection for on-device LLM support
//  Checks physical memory to determine if device can support local AI models
//

import UIKit
import os

/// Utility for checking device capabilities for on-device LLM inference
struct DeviceCapability {

    // MARK: - Memory Requirements

    /// Minimum RAM in GB required for on-device LLM (6GB for Q4_K_M models)
    static let minimumRequiredRAMGB: Double = 6.0

    /// Model size overhead multiplier (model file size * 1.5 for runtime overhead)
    static let modelOverheadMultiplier: Double = 1.5

    // MARK: - Device Information

    /// Get the physical memory of the device in gigabytes
    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000
    }

    /// Get a human-readable description of device memory
    static var memoryDescription: String {
        String(format: "%.1f GB RAM", physicalMemoryGB)
    }

    // MARK: - Capability Checks

    /// Check if device has sufficient RAM for on-device LLM
    /// Requires 6GB+ RAM for Q4_K_M quantized models
    static var canSupportOnDeviceLLM: Bool {
        return physicalMemoryGB >= minimumRequiredRAMGB
    }

    /// Check if device can support a specific model size
    /// - Parameter modelSizeBytes: The size of the model file in bytes
    /// - Returns: True if device has enough memory to load the model
    static func canSupportModel(sizeBytes: Int64) -> Bool {
        let modelSizeGB = Double(sizeBytes) / 1_000_000_000
        let requiredMemoryGB = modelSizeGB * modelOverheadMultiplier

        // Device must have minimum 6GB RAM AND enough for model + overhead
        return physicalMemoryGB >= minimumRequiredRAMGB &&
               physicalMemoryGB >= requiredMemoryGB
    }

    /// Get the recommended quantization for this device
    /// For BisonNotes AI, only Q4_K_M is supported
    static var recommendedQuantization: OnDeviceLLMQuantization? {
        if canSupportOnDeviceLLM {
            return .q4_K_M
        }
        return nil
    }

    // MARK: - User-Facing Messages

    /// Get an appropriate error message for insufficient memory
    static var insufficientMemoryMessage: String {
        if physicalMemoryGB < minimumRequiredRAMGB {
            return """
            On-Device LLM requires an iOS device with at least \(String(format: "%.0f", minimumRequiredRAMGB)) GB of RAM.

            Your device has \(memoryDescription).

            This feature requires a newer device such as:
            • iPhone 14 Pro or newer
            • iPhone 15 or newer
            • iPad Pro with M1 chip or newer
            """
        }
        return "Your device does not meet the minimum requirements for on-device LLM."
    }

    /// Get a user-friendly capability status
    static var capabilityStatus: String {
        if canSupportOnDeviceLLM {
            return "Your device (\(memoryDescription)) supports on-device AI models."
        } else {
            return "Your device (\(memoryDescription)) does not have enough RAM for on-device AI. Requires \(String(format: "%.0f", minimumRequiredRAMGB))GB+ RAM."
        }
    }
}
