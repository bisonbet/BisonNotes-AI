//
//  BisonNotesAITests.swift
//  BisonNotes AITests
//
//  Created by Tim Champ on 7/26/25.
//

import XCTest
@testable import BisonNotes_AI

final class BisonNotesAITests: XCTestCase {
    func testProcessingStatusSemanticFlags() {
        XCTAssertTrue(ProcessingStatus.queued.isActive)
        XCTAssertTrue(ProcessingStatus.processing.isActive)
        XCTAssertTrue(ProcessingStatus.completed.isComplete)
        XCTAssertTrue(ProcessingStatus.failed.hasError)
        XCTAssertTrue(ProcessingStatus.cancelled.hasError)
        XCTAssertTrue(ProcessingStatus.interrupted.isResumable)
        XCTAssertFalse(ProcessingStatus.notStarted.isActive)
    }

    func testChunkingConfigKeepsParakeetAtProvenDurationLimit() {
        let config = ChunkingConfig.config(for: .fluidAudio)
        guard case .duration(let maxSeconds) = config.strategy else {
            return XCTFail("Parakeet should use duration-based chunking")
        }

        XCTAssertEqual(maxSeconds, 10 * 60)
    }

    func testMissingOnDeviceModelThrowsRecoverableError() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-model-\(UUID().uuidString).gguf")

        XCTAssertThrowsError(try OnDeviceLLM(from: missingPath.path)) { error in
            guard let llmError = error as? OnDeviceLLMError,
                  case .configurationError = llmError else {
                return XCTFail("Expected a recoverable model configuration error, got \(error)")
            }
        }
    }
}
