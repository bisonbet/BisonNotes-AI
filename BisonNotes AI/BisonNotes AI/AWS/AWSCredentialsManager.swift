//
//  AWSCredentialsManager.swift
//  BisonNotes AI
//
//  Unified AWS credentials management for all AWS services
//

import Foundation
import AWSClientRuntime

// MARK: - Shared AWS Configuration

struct AWSCredentials: Equatable, Codable {
    let accessKeyId: String
    let secretAccessKey: String
    let region: String
    let sessionToken: String?

    init(
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        sessionToken: String? = nil
    ) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.sessionToken = sessionToken
    }

    private enum CodingKeys: String, CodingKey {
        case accessKeyId
        case secretAccessKey
        case region
        case sessionToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessKeyId = try container.decode(String.self, forKey: .accessKeyId)
        secretAccessKey = try container.decode(String.self, forKey: .secretAccessKey)
        region = try container.decode(String.self, forKey: .region)
        sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessKeyId, forKey: .accessKeyId)
        try container.encode(secretAccessKey, forKey: .secretAccessKey)
        try container.encode(region, forKey: .region)
        try container.encodeIfPresent(sessionToken, forKey: .sessionToken)
    }

    var isValid: Bool {
        return !accessKeyId.isEmpty && !secretAccessKey.isEmpty && !region.isEmpty
    }

    static let `default` = AWSCredentials(
        accessKeyId: "",
        secretAccessKey: "",
        region: "us-east-1"
    )
}

// MARK: - AWS Credentials Manager

class AWSCredentialsManager: ObservableObject {
    @Published var credentials: AWSCredentials

    private let userDefaults: UserDefaults
    private let keychain: KeychainSecretStore
    private let credentialsKey = KeychainSecretStore.awsCredentials

    init(
        keychain: KeychainSecretStore = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.userDefaults = userDefaults
        self.credentials = .default
        migrateLegacyCredentials()

        // Load saved credentials or use default
        if let data = keychain.data(forKey: credentialsKey),
           let savedCredentials = try? JSONDecoder().decode(AWSCredentials.self, from: data) {
            self.credentials = savedCredentials
        } else {
            self.credentials = .default
        }
        clearCredentialEnvironment()
    }

    @discardableResult
    func updateCredentials(_ newCredentials: AWSCredentials) -> Bool {
        guard saveCredentials(newCredentials, removeLegacySessionToken: newCredentials.sessionToken != nil) else {
            return false
        }
        self.credentials = newCredentials
        clearCredentialEnvironment()
        return true
    }

    @discardableResult
    func updateAccessKey(_ accessKey: String) -> Bool {
        let updated = AWSCredentials(
            accessKeyId: accessKey,
            secretAccessKey: credentials.secretAccessKey,
            region: credentials.region,
            sessionToken: credentials.sessionToken
        )
        return updateCredentials(updated)
    }

    @discardableResult
    func updateSecretKey(_ secretKey: String) -> Bool {
        let updated = AWSCredentials(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: secretKey,
            region: credentials.region,
            sessionToken: credentials.sessionToken
        )
        return updateCredentials(updated)
    }

    @discardableResult
    func updateRegion(_ region: String) -> Bool {
        let updated = AWSCredentials(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            region: region,
            sessionToken: credentials.sessionToken
        )
        return updateCredentials(updated)
    }

    @discardableResult
    func updateSessionToken(_ sessionToken: String) -> Bool {
        let normalizedToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = AWSCredentials(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            region: credentials.region,
            sessionToken: normalizedToken.isEmpty ? nil : normalizedToken
        )
        return updateCredentials(updated, removeLegacySessionToken: true)
    }

    private func updateCredentials(
        _ newCredentials: AWSCredentials,
        removeLegacySessionToken: Bool
    ) -> Bool {
        guard saveCredentials(newCredentials, removeLegacySessionToken: removeLegacySessionToken) else {
            return false
        }
        self.credentials = newCredentials
        clearCredentialEnvironment()
        return true
    }

    private func saveCredentials(
        _ credentials: AWSCredentials,
        removeLegacySessionToken: Bool
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else {
            AppLog.shared.general(
                "AWS credential persistence failed: unable to encode credentials",
                level: .error
            )
            return false
        }

        switch keychain.setData(data, forKey: credentialsKey) {
        case .success:
            removeLegacyUserDefaults(removeSessionToken: removeLegacySessionToken)
            if removeLegacySessionToken {
                removeLegacySessionTokenFromKeychain()
            }
            return true
        case .failure(let error):
            AppLog.shared.general(
                "AWS credential persistence failed: \(error.localizedDescription)",
                level: .error
            )
            return false
        }
    }

    private func migrateLegacyCredentials() {
        let existingData = keychain.data(forKey: credentialsKey)
        let existingCredentials = existingData.flatMap(decodeCredentials)
        guard existingData == nil || existingCredentials != nil else {
            AppLog.shared.general(
                "AWS credential migration skipped: stored credentials could not be decoded",
                level: .error
            )
            return
        }

        let legacyBlobData = userDefaults.data(forKey: credentialsKey)
        let legacyBlob = legacyBlobData.flatMap(decodeCredentials)
        guard legacyBlobData == nil || legacyBlob != nil else {
            AppLog.shared.general(
                "AWS credential migration skipped: legacy credentials could not be decoded",
                level: .error
            )
            return
        }

        let legacySessionToken = normalizedSessionToken(
            keychain.string(forKey: KeychainSecretStore.awsBedrockSessionToken)
                ?? userDefaults.string(forKey: KeychainSecretStore.awsBedrockSessionToken)
        )
        let baseCredentials = existingCredentials ?? legacyBlob ?? legacyKeyCredentials()
        let migratedCredentials = mergedCredentials(
            base: baseCredentials,
            legacySessionToken: legacySessionToken
        )

        guard let migratedCredentials else {
            if existingCredentials != nil {
                removeLegacyUserDefaults(removeSessionToken: false)
            }
            return
        }

        let shouldSave = existingCredentials == nil || migratedCredentials != existingCredentials
        if shouldSave {
            guard saveCredentials(
                migratedCredentials,
                removeLegacySessionToken: legacySessionToken != nil
            ) else {
                return
            }
        } else {
            removeLegacyUserDefaults(removeSessionToken: legacySessionToken != nil)
            if legacySessionToken != nil {
                removeLegacySessionTokenFromKeychain()
            }
        }
    }

    private func legacyKeyCredentials() -> AWSCredentials? {
        let accessKey = userDefaults.string(forKey: "awsAccessKey") ?? ""
        let secretKey = userDefaults.string(forKey: "awsSecretKey") ?? ""
        guard !accessKey.isEmpty || !secretKey.isEmpty else { return nil }

        let storedRegion = userDefaults.string(forKey: "awsRegion") ?? AWSCredentials.default.region
        return AWSCredentials(
            accessKeyId: accessKey,
            secretAccessKey: secretKey,
            region: storedRegion.isEmpty ? AWSCredentials.default.region : storedRegion
        )
    }

    private func mergedCredentials(
        base: AWSCredentials?,
        legacySessionToken: String?
    ) -> AWSCredentials? {
        guard let base else {
            guard let legacySessionToken else { return nil }
            return AWSCredentials(
                accessKeyId: AWSCredentials.default.accessKeyId,
                secretAccessKey: AWSCredentials.default.secretAccessKey,
                region: AWSCredentials.default.region,
                sessionToken: legacySessionToken
            )
        }

        guard let legacySessionToken, base.sessionToken == nil else {
            return base
        }
        return AWSCredentials(
            accessKeyId: base.accessKeyId,
            secretAccessKey: base.secretAccessKey,
            region: base.region,
            sessionToken: legacySessionToken
        )
    }

    private func decodeCredentials(_ data: Data) -> AWSCredentials? {
        try? JSONDecoder().decode(AWSCredentials.self, from: data)
    }

    private func normalizedSessionToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedToken.isEmpty ? nil : normalizedToken
    }

    private func removeLegacyUserDefaults(removeSessionToken: Bool) {
        userDefaults.removeObject(forKey: credentialsKey)
        userDefaults.removeObject(forKey: "awsAccessKey")
        userDefaults.removeObject(forKey: "awsSecretKey")
        userDefaults.removeObject(forKey: "awsRegion")
        if removeSessionToken {
            userDefaults.removeObject(forKey: KeychainSecretStore.awsBedrockSessionToken)
        }
    }

    private func removeLegacySessionTokenFromKeychain() {
        if case .failure(let error) = keychain.delete(forKey: KeychainSecretStore.awsBedrockSessionToken) {
            AppLog.shared.general(
                "AWS session-token cleanup failed: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func clearCredentialEnvironment() {
        unsetenv("AWS_ACCESS_KEY_ID")
        unsetenv("AWS_SECRET_ACCESS_KEY")
        unsetenv("AWS_SESSION_TOKEN")
        unsetenv("AWS_DEFAULT_REGION")
    }

}

// MARK: - Global Shared Instance

extension AWSCredentialsManager {
    static let shared = AWSCredentialsManager()
}
