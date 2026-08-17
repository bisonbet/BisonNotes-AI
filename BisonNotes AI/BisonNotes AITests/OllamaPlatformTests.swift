//
//  OllamaPlatformTests.swift
//  BisonNotes AITests
//

import Foundation
import XCTest
@testable import BisonNotes_AI

@MainActor
final class OllamaPlatformTests: XCTestCase {
    func testOllamaIsExposedOnlyOnNativeMac() {
#if os(macOS)
        XCTAssertTrue(AIEngineType.availableCases.contains(.localLLM))
#else
        XCTAssertFalse(AIEngineType.availableCases.contains(.localLLM))
        XCTAssertFalse(LocalLLMEngine().isAvailable)
#endif
    }

    func testLegacyOllamaMigrationPrefersOnDeviceEngines() {
        XCTAssertEqual(
            AIEngineType.preferredOnDeviceMigrationEngine(supportsMLX: true, supportsOnDeviceLLM: true),
            .mlxSwift
        )
        XCTAssertEqual(
            AIEngineType.preferredOnDeviceMigrationEngine(supportsMLX: false, supportsOnDeviceLLM: true),
            .onDeviceLLM
        )
        XCTAssertNil(
            AIEngineType.preferredOnDeviceMigrationEngine(supportsMLX: false, supportsOnDeviceLLM: false)
        )
    }

    func testOllamaDefaultsToTheMacLocalServer() {
        XCTAssertEqual(AppSettingsKeys.Defaults.ollamaServerURL, "http://localhost")
        XCTAssertEqual(AppSettingsKeys.Defaults.ollamaPort, 11434)
        XCTAssertEqual(AppSettingsKeys.Defaults.ollamaModelName, "llama3.2")
        XCTAssertEqual(OllamaConfig.default.modelName, AppSettingsKeys.Defaults.ollamaModelName)
        XCTAssertEqual(OllamaConfig.default.baseURL, "http://localhost:11434")
    }

#if os(macOS)
    func testMacOllamaDefaultsPreserveCustomServerValues() {
        let suiteName = "OllamaPlatformTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppSettingsKeys.applyOllamaMacDefaultsIfNeeded(to: defaults)
        XCTAssertEqual(defaults.string(forKey: AppSettingsKeys.ollamaServerURL), "http://localhost")
        XCTAssertEqual(defaults.integer(forKey: AppSettingsKeys.ollamaPort), 11434)
        XCTAssertEqual(defaults.string(forKey: AppSettingsKeys.ollamaModelName), "llama3.2")

        defaults.set("http://custom-server", forKey: AppSettingsKeys.ollamaServerURL)
        defaults.set(12345, forKey: AppSettingsKeys.ollamaPort)
        defaults.set("custom-model", forKey: AppSettingsKeys.ollamaModelName)
        AppSettingsKeys.applyOllamaMacDefaultsIfNeeded(to: defaults)

        XCTAssertEqual(defaults.string(forKey: AppSettingsKeys.ollamaServerURL), "http://custom-server")
        XCTAssertEqual(defaults.integer(forKey: AppSettingsKeys.ollamaPort), 12345)
        XCTAssertEqual(defaults.string(forKey: AppSettingsKeys.ollamaModelName), "custom-model")
    }
#endif
}
