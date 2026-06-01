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
    
    private let userDefaults = UserDefaults.standard
    private let keychain = KeychainSecretStore.shared
    private let credentialsKey = KeychainSecretStore.awsCredentials
    
    init() {
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
    
    func updateCredentials(_ newCredentials: AWSCredentials) {
        self.credentials = newCredentials
        saveCredentials()
        clearCredentialEnvironment()
    }
    
    func updateAccessKey(_ accessKey: String) {
        let updated = AWSCredentials(
            accessKeyId: accessKey,
            secretAccessKey: credentials.secretAccessKey,
            region: credentials.region
        )
        updateCredentials(updated)
    }
    
    func updateSecretKey(_ secretKey: String) {
        let updated = AWSCredentials(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: secretKey,
            region: credentials.region
        )
        updateCredentials(updated)
    }
    
    func updateRegion(_ region: String) {
        let updated = AWSCredentials(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            region: region
        )
        updateCredentials(updated)
    }
    
    private func saveCredentials() {
        if let data = try? JSONEncoder().encode(credentials) {
            keychain.setData(data, forKey: credentialsKey)
        }
        userDefaults.removeObject(forKey: credentialsKey)
        userDefaults.removeObject(forKey: "awsAccessKey")
        userDefaults.removeObject(forKey: "awsSecretKey")
        userDefaults.removeObject(forKey: "awsRegion")
    }

    private func migrateLegacyCredentials() {
        if keychain.data(forKey: credentialsKey) == nil,
           let data = userDefaults.data(forKey: credentialsKey) {
            keychain.setData(data, forKey: credentialsKey)
        } else if keychain.data(forKey: credentialsKey) == nil {
            let accessKey = userDefaults.string(forKey: "awsAccessKey") ?? ""
            let secretKey = userDefaults.string(forKey: "awsSecretKey") ?? ""
            let region = userDefaults.string(forKey: "awsRegion") ?? AWSCredentials.default.region

            if !accessKey.isEmpty || !secretKey.isEmpty {
                let legacyCredentials = AWSCredentials(
                    accessKeyId: accessKey,
                    secretAccessKey: secretKey,
                    region: region.isEmpty ? AWSCredentials.default.region : region
                )
                if let data = try? JSONEncoder().encode(legacyCredentials) {
                    keychain.setData(data, forKey: credentialsKey)
                }
            }
        }

        userDefaults.removeObject(forKey: credentialsKey)
        userDefaults.removeObject(forKey: "awsAccessKey")
        userDefaults.removeObject(forKey: "awsSecretKey")
        userDefaults.removeObject(forKey: "awsRegion")
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
