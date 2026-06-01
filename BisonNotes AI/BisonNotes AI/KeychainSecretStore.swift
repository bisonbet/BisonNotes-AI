//
//  KeychainSecretStore.swift
//  BisonNotes AI
//
//  Keychain-backed storage for API keys and cloud credentials.
//

import Foundation
import Security
import SwiftUI

final class KeychainSecretStore {
    static let shared = KeychainSecretStore()

    static let openAIAPIKey = "openAIAPIKey"
    static let openAICompatibleAPIKey = "openAICompatibleAPIKey"
    static let googleAIStudioAPIKey = "googleAIStudioAPIKey"
    static let mistralAPIKey = "mistralAPIKey"
    static let awsCredentials = "AWSCredentials"
    static let awsBedrockSessionToken = "awsBedrockSessionToken"

    private static let stringSecretKeys = [
        openAIAPIKey,
        openAICompatibleAPIKey,
        googleAIStudioAPIKey,
        mistralAPIKey,
        awsBedrockSessionToken
    ]

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.bisonnotes.ai") {
        self.service = "\(service).secrets"
    }

    func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setString(_ value: String, forKey key: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            delete(forKey: key)
            return
        }

        guard let data = trimmedValue.data(using: .utf8) else { return }
        setData(data, forKey: key)
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

    func setData(_ data: Data, forKey key: String) {
        var query = baseQuery(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status != errSecSuccess else { return }

        if status != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }

        query.merge(attributes) { _, new in new }
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete(forKey key: String) {
        SecItemDelete(baseQuery(forKey: key) as CFDictionary)
    }

    func migrateLegacySecretsFromUserDefaults(_ defaults: UserDefaults = .standard) {
        for key in Self.stringSecretKeys {
            if data(forKey: key) == nil, let legacyValue = defaults.string(forKey: key), !legacyValue.isEmpty {
                setString(legacyValue, forKey: key)
            }
            defaults.removeObject(forKey: key)
        }

        if data(forKey: Self.awsCredentials) == nil, let legacyData = defaults.data(forKey: Self.awsCredentials) {
            setData(legacyData, forKey: Self.awsCredentials)
        }
        defaults.removeObject(forKey: Self.awsCredentials)
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
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
            KeychainSecretStore.shared.setString(newValue, forKey: key)
        }
    }

    var projectedValue: Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}
