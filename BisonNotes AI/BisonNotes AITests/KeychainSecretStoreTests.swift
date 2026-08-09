//
//  KeychainSecretStoreTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

final class KeychainSecretStoreTests: XCTestCase {
    private var store: KeychainSecretStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "KeychainSecretStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = KeychainSecretStore(service: "com.bisonnotes.tests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        [
            KeychainSecretStore.openAIAPIKey,
            KeychainSecretStore.openAICompatibleAPIKey,
            KeychainSecretStore.googleAIStudioAPIKey,
            KeychainSecretStore.mistralAPIKey
        ].forEach { _ = store.delete(forKey: $0) }

        KeychainSecretStore.legacyAWSSettingKeys.forEach { _ = store.delete(forKey: $0) }

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCreatesAndUpdatesKeychainSecret() {
        assertSuccess(store.setString("temporary-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey))
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey), "temporary-secret")

        assertSuccess(store.setString("updated-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey))
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey), "updated-secret")
    }

    func testDeletesKeychainSecretAndTreatsMissingItemAsSuccess() {
        assertSuccess(store.setString("temporary-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey))

        assertSuccess(store.delete(forKey: KeychainSecretStore.googleAIStudioAPIKey))
        XCTAssertNil(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey))

        assertSuccess(store.delete(forKey: KeychainSecretStore.googleAIStudioAPIKey))
    }

    func testMigratesStringSecretsFromUserDefaultsToKeychain() throws {
        defaults.set("sk-test-openai", forKey: KeychainSecretStore.openAIAPIKey)
        defaults.set("mistral-test-key", forKey: KeychainSecretStore.mistralAPIKey)

        XCTAssertTrue(store.migrateLegacySecretsFromUserDefaults(defaults).isEmpty)

        XCTAssertNil(defaults.string(forKey: KeychainSecretStore.openAIAPIKey))
        XCTAssertNil(defaults.string(forKey: KeychainSecretStore.mistralAPIKey))
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.openAIAPIKey), "sk-test-openai")
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.mistralAPIKey), "mistral-test-key")
    }

    func testEmptyStringDeletesKeychainSecret() {
        assertSuccess(store.setString("temporary-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey))
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey), "temporary-secret")

        assertSuccess(store.setString("updated-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey))
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey), "updated-secret")

        assertSuccess(store.setString("", forKey: KeychainSecretStore.googleAIStudioAPIKey))

        XCTAssertNil(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey))
    }

    func testRemovesLegacyAWSSecretsFromUserDefaultsAndKeychain() {
        defaults.set(Data("legacy-credentials".utf8), forKey: KeychainSecretStore.legacyAWSCredentials)
        defaults.set("legacy-session-token", forKey: KeychainSecretStore.legacyAWSBedrockSessionToken)
        assertSuccess(
            store.setData(Data("keychain-credentials".utf8), forKey: KeychainSecretStore.legacyAWSCredentials)
        )

        XCTAssertTrue(store.migrateLegacySecretsFromUserDefaults(defaults).isEmpty)

        KeychainSecretStore.legacyAWSSettingKeys.forEach { key in
            XCTAssertNil(defaults.object(forKey: key), "Legacy AWS setting should be removed: \(key)")
            XCTAssertNil(store.data(forKey: key), "Legacy AWS secret should be removed: \(key)")
        }
    }

    private func assertSuccess(
        _ result: Result<Void, KeychainSecretStoreError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Keychain mutation failed: \(error.localizedDescription)", file: file, line: line)
        }
    }
}
