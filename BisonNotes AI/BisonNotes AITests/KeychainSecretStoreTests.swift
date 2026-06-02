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
            KeychainSecretStore.mistralAPIKey,
            KeychainSecretStore.awsBedrockSessionToken,
            KeychainSecretStore.awsCredentials
        ].forEach { store.delete(forKey: $0) }

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMigratesStringSecretsFromUserDefaultsToKeychain() throws {
        defaults.set("sk-test-openai", forKey: KeychainSecretStore.openAIAPIKey)
        defaults.set("mistral-test-key", forKey: KeychainSecretStore.mistralAPIKey)

        store.migrateLegacySecretsFromUserDefaults(defaults)

        XCTAssertNil(defaults.string(forKey: KeychainSecretStore.openAIAPIKey))
        XCTAssertNil(defaults.string(forKey: KeychainSecretStore.mistralAPIKey))
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.openAIAPIKey), "sk-test-openai")
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.mistralAPIKey), "mistral-test-key")
    }

    func testMigratesAWSCredentialsBlobFromUserDefaultsToKeychain() throws {
        let credentials = AWSCredentials(
            accessKeyId: "AKIATEST",
            secretAccessKey: "aws-secret-test",
            region: "us-west-2"
        )
        let encoded = try JSONEncoder().encode(credentials)
        defaults.set(encoded, forKey: KeychainSecretStore.awsCredentials)

        store.migrateLegacySecretsFromUserDefaults(defaults)

        XCTAssertNil(defaults.data(forKey: KeychainSecretStore.awsCredentials))

        let migratedData = try XCTUnwrap(store.data(forKey: KeychainSecretStore.awsCredentials))
        let migratedCredentials = try JSONDecoder().decode(AWSCredentials.self, from: migratedData)
        XCTAssertEqual(migratedCredentials, credentials)
    }

    func testEmptyStringDeletesKeychainSecret() {
        store.setString("temporary-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey)
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey), "temporary-secret")

        store.setString("updated-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey)
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey), "updated-secret")

        store.setString("", forKey: KeychainSecretStore.googleAIStudioAPIKey)

        XCTAssertNil(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey))
    }
}
