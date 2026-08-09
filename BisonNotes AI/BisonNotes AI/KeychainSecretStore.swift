//
//  KeychainSecretStore.swift
//  BisonNotes AI
//
//  Keychain-backed storage for API keys and legacy-secret cleanup.
//

import Foundation
import Security
import SwiftUI

enum KeychainSecretStoreError: Equatable, LocalizedError {
    enum Operation: String {
        case add
        case update
        case delete
    }

    case invalidString
    case operationFailed(operation: Operation, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidString:
            return "The secure value could not be encoded."
        case .operationFailed(let operation, let status):
            return "Keychain \(operation.rawValue) failed with status \(status)."
        }
    }
}

final class KeychainSecretStore {
    static let shared = KeychainSecretStore()

    static let openAIAPIKey = "openAIAPIKey"
    static let openAICompatibleAPIKey = "openAICompatibleAPIKey"
    static let googleAIStudioAPIKey = "googleAIStudioAPIKey"
    static let mistralAPIKey = "mistralAPIKey"
    static let legacyAWSCredentials = "AWSCredentials"
    static let legacyAWSBedrockSessionToken = "awsBedrockSessionToken"

    /// Settings and secret identifiers written by builds that included AWS.
    /// AWS is no longer supported, so old values must not be restored into
    /// UserDefaults or retained in the app's Keychain namespace.
    static let legacyAWSSettingKeys: Set<String> = [
        legacyAWSCredentials,
        legacyAWSBedrockSessionToken,
        "awsAccessKey",
        "awsSecretKey",
        "awsSecretAccessKey",
        "awsRegion",
        "awsBucketName",
        "awsBedrockModel",
        "awsBedrockTemperature",
        "awsBedrockMaxTokens",
        "awsBedrockUseProfile",
        "awsBedrockProfileName",
        "awsBedrockModelMigrated_v1.3",
        "enableAWSBedrock",
        "enableAWSTranscribe"
    ]

    static func isLegacyAWSSettingKey(_ key: String) -> Bool {
        legacyAWSSettingKeys.contains(key)
    }

    private static let stringSecretKeys = [
        openAIAPIKey,
        openAICompatibleAPIKey,
        googleAIStudioAPIKey,
        mistralAPIKey
    ]

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.bisonnotes.ai") {
        self.service = "\(service).secrets"
    }

    func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setString(_ value: String, forKey key: String) -> Result<Void, KeychainSecretStoreError> {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return delete(forKey: key)
        }

        guard let data = trimmedValue.data(using: .utf8) else {
            return report(.failure(.invalidString))
        }
        return setData(data, forKey: key)
    }

    func data(forKey key: String) -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func setData(_ data: Data, forKey key: String) -> Result<Void, KeychainSecretStoreError> {
        var query = baseQuery(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return .success(())
        case errSecItemNotFound:
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return .success(())
            case errSecDuplicateItem:
                let retryStatus = SecItemUpdate(
                    baseQuery(forKey: key) as CFDictionary,
                    attributes as CFDictionary
                )
                if retryStatus == errSecSuccess {
                    return .success(())
                }
                return report(.failure(.operationFailed(operation: .update, status: retryStatus)))
            default:
                return report(.failure(.operationFailed(operation: .add, status: addStatus)))
            }
        default:
            return report(.failure(.operationFailed(operation: .update, status: status)))
        }
    }

    @discardableResult
    func delete(forKey key: String) -> Result<Void, KeychainSecretStoreError> {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return .success(())
        default:
            return report(.failure(.operationFailed(operation: .delete, status: status)))
        }
    }

    @discardableResult
    func migrateLegacySecretsFromUserDefaults(_ defaults: UserDefaults = .standard) -> [KeychainSecretStoreError] {
        var failures: [KeychainSecretStoreError] = []

        for key in Self.stringSecretKeys {
            if data(forKey: key) == nil, let legacyValue = defaults.string(forKey: key), !legacyValue.isEmpty {
                let result = setString(legacyValue, forKey: key)
                if case .failure(let error) = result {
                    failures.append(error)
                    continue
                }
            }
            defaults.removeObject(forKey: key)
        }

        // AWS provider support was removed. Clean up old opaque credential
        // blobs and individual AWS fields instead of migrating them to a
        // credential format that no current provider consumes.
        for key in Self.legacyAWSSettingKeys {
            let result = delete(forKey: key)
            if case .failure(let error) = result {
                failures.append(error)
                continue
            }
            defaults.removeObject(forKey: key)
        }

        return failures
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func report(
        _ result: Result<Void, KeychainSecretStoreError>
    ) -> Result<Void, KeychainSecretStoreError> {
        if case .failure(let error) = result {
            AppLog.shared.general(
                "Secure credential storage operation failed: \(error.localizedDescription)",
                level: .error
            )
        }
        return result
    }
}

@propertyWrapper
struct SecureStorage: DynamicProperty {
    private let key: String
    private let defaultValue: String
    @State private var value: String

    init(wrappedValue defaultValue: String, _ key: String) {
        self.key = key
        self.defaultValue = defaultValue
        _value = State(initialValue: KeychainSecretStore.shared.string(forKey: key) ?? defaultValue)
    }

    func update() {
        let storedValue = KeychainSecretStore.shared.string(forKey: key) ?? defaultValue
        if storedValue != value {
            value = storedValue
        }
    }

    var wrappedValue: String {
        get { value }
        nonmutating set {
            value = newValue
            let result = KeychainSecretStore.shared.setString(newValue, forKey: key)
            if case .failure(let error) = result {
                AppLog.shared.general(
                    "Secure setting persistence failed: \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    var projectedValue: Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}
