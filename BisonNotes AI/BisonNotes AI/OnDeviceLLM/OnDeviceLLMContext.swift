//
//  OnDeviceLLMContext.swift
//  BisonNotes AI
//
//  llama.cpp context wrapper for on-device LLM
//  Adapted from OLMoE.swift project
//

import Foundation
import llama

// MARK: - Decode Error

/// Error type for llama decode failures
public enum LLMDecodeError: Error, LocalizedError {
    case decodeFailed(code: Int32)
    case contextNotReady

    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let code):
            return "LLM decode failed with error code: \(code)"
        case .contextNotReady:
            return "LLM context is not ready for decoding"
        }
    }
}

// MARK: - LLM Context Wrapper

/// Wrapper class for llama.cpp context management
public class LLMContext {
    let pointer: OpaquePointer
    private(set) var lastDecodeError: LLMDecodeError?

    init(_ model: LLMModel, _ params: llama_context_params) {
        self.pointer = llama_init_from_model(model, params)
    }

    deinit {
        llama_free(pointer)
    }

    /// Decode a batch of tokens. Returns true on success, false on failure.
    /// Check `lastDecodeError` for details if this returns false.
    @discardableResult
    func decode(_ batch: llama_batch) -> Bool {
        lastDecodeError = nil
        let ret = llama_decode(pointer, batch)

        if ret < 0 {
            lastDecodeError = .decodeFailed(code: ret)
            print("[LLMContext] llama_decode failed with code: \(ret)")
            return false
        } else if ret > 0 {
            if OnDeviceLLMFeatureFlags.verboseLogging {
                print("[LLMContext] llama_decode returned \(ret)")
            }
        }
        return true
    }
}
