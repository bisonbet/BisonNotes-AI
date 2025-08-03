//
//  AWSCredentialsManager.swift
//  BisonNotes AI
//
//  Unified AWS credentials management for all AWS services
//

import Foundation

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
    private let credentialsKey = "AWSCredentials"
    
    init() {
        // Load saved credentials or use default
        if let data = userDefaults.data(forKey: credentialsKey),
           let savedCredentials = try? JSONDecoder().decode(AWSCredentials.self, from: data) {
            self.credentials = savedCredentials
        } else {
            self.credentials = .default
        }
    }
    
    func updateCredentials(_ newCredentials: AWSCredentials) {
        self.credentials = newCredentials
        saveCredentials()
        configureEnvironmentVariables()
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
            userDefaults.set(data, forKey: credentialsKey)
        }
    }
    
    private func configureEnvironmentVariables() {
        // Set environment variables for AWS SDK
        if credentials.isValid {
            setenv("AWS_ACCESS_KEY_ID", credentials.accessKeyId, 1)
            setenv("AWS_SECRET_ACCESS_KEY", credentials.secretAccessKey, 1)
            setenv("AWS_DEFAULT_REGION", credentials.region, 1)
            print("✅ AWS credentials configured globally")
        } else {
            print("⚠️ AWS credentials incomplete - not setting environment variables")
        }
    }
    
    // Call this when app starts to ensure environment variables are set
    func initializeEnvironment() {
        configureEnvironmentVariables()
    }
}

// MARK: - Global Shared Instance

extension AWSCredentialsManager {
    static let shared = AWSCredentialsManager()
}