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
        ].forEach { _ = store.delete(forKey: $0) }

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

    func testMigratesAWSCredentialsBlobFromUserDefaultsToKeychain() throws {
        let credentials = AWSCredentials(
            accessKeyId: "AKIATEST",
            secretAccessKey: "aws-secret-test",
            region: "us-west-2"
        )
        let encoded = try JSONEncoder().encode(credentials)
        defaults.set(encoded, forKey: KeychainSecretStore.awsCredentials)

        XCTAssertTrue(store.migrateLegacySecretsFromUserDefaults(defaults).isEmpty)

        XCTAssertNil(defaults.data(forKey: KeychainSecretStore.awsCredentials))

        let migratedData = try XCTUnwrap(store.data(forKey: KeychainSecretStore.awsCredentials))
        let migratedCredentials = try JSONDecoder().decode(AWSCredentials.self, from: migratedData)
        XCTAssertEqual(migratedCredentials, credentials)
    }

    func testEmptyStringDeletesKeychainSecret() {
        assertSuccess(store.setString("temporary-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey))
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey), "temporary-secret")

        assertSuccess(store.setString("updated-secret", forKey: KeychainSecretStore.googleAIStudioAPIKey))
        XCTAssertEqual(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey), "updated-secret")

        assertSuccess(store.setString("", forKey: KeychainSecretStore.googleAIStudioAPIKey))

        XCTAssertNil(store.string(forKey: KeychainSecretStore.googleAIStudioAPIKey))
    }

    func testDecodesLegacyThreeFieldAWSCredentials() throws {
        let legacyData = Data(
            #"{"accessKeyId":"AKIATEST","secretAccessKey":"aws-secret-test","region":"us-west-2"}"#.utf8
        )

        let credentials = try JSONDecoder().decode(AWSCredentials.self, from: legacyData)

        XCTAssertEqual(credentials.accessKeyId, "AKIATEST")
        XCTAssertEqual(credentials.secretAccessKey, "aws-secret-test")
        XCTAssertEqual(credentials.region, "us-west-2")
        XCTAssertNil(credentials.sessionToken)
    }

    func testAWSCredentialsWithSessionTokenRoundTrips() throws {
        let credentials = AWSCredentials(
            accessKeyId: "AKIATEST",
            secretAccessKey: "aws-secret-test",
            region: "us-west-2",
            sessionToken: "session-token-test"
        )

        let encoded = try JSONEncoder().encode(credentials)
        let decoded = try JSONDecoder().decode(AWSCredentials.self, from: encoded)

        XCTAssertEqual(decoded, credentials)
    }

    func testMigratesLegacySessionTokenIntoUnifiedCredentials() throws {
        defaults.set("AKIATEST", forKey: "awsAccessKey")
        defaults.set("aws-secret-test", forKey: "awsSecretKey")
        defaults.set("us-west-2", forKey: "awsRegion")
        assertSuccess(store.setString("session-token-test", forKey: KeychainSecretStore.awsBedrockSessionToken))

        let manager = AWSCredentialsManager(keychain: store, userDefaults: defaults)

        XCTAssertEqual(manager.credentials.sessionToken, "session-token-test")
        XCTAssertNil(store.string(forKey: KeychainSecretStore.awsBedrockSessionToken))
        XCTAssertNil(defaults.string(forKey: "awsAccessKey"))
        XCTAssertNil(defaults.string(forKey: "awsSecretKey"))
        XCTAssertNil(defaults.string(forKey: "awsRegion"))

        let unifiedData = try XCTUnwrap(store.data(forKey: KeychainSecretStore.awsCredentials))
        let unifiedCredentials = try JSONDecoder().decode(AWSCredentials.self, from: unifiedData)
        XCTAssertEqual(unifiedCredentials.sessionToken, "session-token-test")
    }

    func testStaticResolverPassesSessionToken() async throws {
        let credentials = AWSCredentials(
            accessKeyId: "AKIATEST",
            secretAccessKey: "aws-secret-test",
            region: "us-west-2",
            sessionToken: "session-token-test"
        )

        let identity = try await AWSClientCredentialResolver
            .staticResolver(credentials: credentials)
            .getIdentity(identityProperties: nil)

        XCTAssertEqual(identity.accessKey, "AKIATEST")
        XCTAssertEqual(identity.secret, "aws-secret-test")
        XCTAssertEqual(identity.sessionToken, "session-token-test")
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
