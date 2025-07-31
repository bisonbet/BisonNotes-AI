//
//  AWSSettingsView.swift
//  Audio Journal
//
//  Settings view for AWS Transcribe configuration
//

import SwiftUI

struct AWSSettingsView: View {
    @AppStorage("awsAccessKey") private var accessKey: String = ""
    @AppStorage("awsSecretKey") private var secretKey: String = ""
    @AppStorage("awsRegion") private var region: String = "us-east-1"
    @AppStorage("awsBucketName") private var bucketName: String = ""
    @AppStorage("enableAWSTranscribe") private var enableAWSTranscribe: Bool = false
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingCredentials = false
    @State private var testResult: String?
    @State private var isTesting = false
    
    private let regions = [
        "us-east-1": "US East (N. Virginia)",
        "us-east-2": "US East (Ohio)",
        "us-west-1": "US West (N. California)",
        "us-west-2": "US West (Oregon)",
        "eu-west-1": "Europe (Ireland)",
        "eu-central-1": "Europe (Frankfurt)",
        "ap-southeast-1": "Asia Pacific (Singapore)",
        "ap-southeast-2": "Asia Pacific (Sydney)",
        "ap-northeast-1": "Asia Pacific (Tokyo)"
    ]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("AWS Transcribe")) {
                    Toggle("Enable AWS Transcribe", isOn: $enableAWSTranscribe)
                    
                    if enableAWSTranscribe {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AWS Transcribe provides high-quality transcription for large audio files with better accuracy than local transcription.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                if enableAWSTranscribe {
                    Section(header: Text("AWS Credentials")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Access Key ID")
                                Spacer()
                                Button("Show/Hide") {
                                    showingCredentials.toggle()
                                }
                                .font(.caption)
                            }
                            
                            if showingCredentials {
                                TextField("Enter Access Key ID", text: $accessKey)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            } else {
                                SecureField("Enter Access Key ID", text: $accessKey)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                            
                            HStack {
                                Text("Secret Access Key")
                                Spacer()
                                Button("Show/Hide") {
                                    showingCredentials.toggle()
                                }
                                .font(.caption)
                            }
                            
                            if showingCredentials {
                                TextField("Enter Secret Access Key", text: $secretKey)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            } else {
                                SecureField("Enter Secret Access Key", text: $secretKey)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Security Note")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                            
                            Text("Your AWS credentials are stored securely on your device. Never share these credentials or commit them to version control.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Section(header: Text("AWS Configuration")) {
                        Picker("Region", selection: $region) {
                            ForEach(Array(regions.keys.sorted()), id: \.self) { key in
                                Text("\(key) - \(regions[key] ?? "")")
                                    .tag(key)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("S3 Bucket Name")
                                .font(.headline)
                            
                            TextField("Enter S3 bucket name", text: $bucketName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            
                            Text("This bucket will store your audio files temporarily during transcription. Make sure it exists and your credentials have access to it.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Section(header: Text("Test Connection")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Button(action: testConnection) {
                                HStack {
                                    if isTesting {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "network")
                                    }
                                    Text(isTesting ? "Testing..." : "Test AWS Connection")
                                }
                            }
                            .disabled(isTesting || !isConfigurationValid)
                            
                            if let testResult = testResult {
                                Text(testResult)
                                    .font(.caption)
                                    .foregroundColor(testResult.contains("✅") ? .green : .red)
                            }
                        }
                    }
                    
                    Section(header: Text("Setup Instructions")) {
                        VStack(alignment: .leading, spacing: 12) {
                            InstructionRow(
                                number: "1",
                                title: "Create AWS Account",
                                description: "Sign up for AWS if you don't have an account"
                            )
                            
                            InstructionRow(
                                number: "2",
                                title: "Create IAM User",
                                description: "Create an IAM user with Transcribe and S3 permissions"
                            )
                            
                            InstructionRow(
                                number: "3",
                                title: "Create S3 Bucket",
                                description: "Create an S3 bucket for storing audio files"
                            )
                            
                            InstructionRow(
                                number: "4",
                                title: "Get Credentials",
                                description: "Generate Access Key ID and Secret Access Key"
                            )
                            
                            InstructionRow(
                                number: "5",
                                title: "Configure App",
                                description: "Enter your credentials and bucket name above"
                            )
                        }
                    }
                    
                    Section {
                        Link("AWS Transcribe Documentation", destination: URL(string: "https://docs.aws.amazon.com/transcribe/")!)
                        Link("AWS IAM Setup Guide", destination: URL(string: "https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html")!)
                    }
                }
            }
            .navigationTitle("AWS Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var isConfigurationValid: Bool {
        !accessKey.isEmpty && !secretKey.isEmpty && !bucketName.isEmpty
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            do {
                let config = AWSTranscribeConfig(
                    region: region,
                    accessKey: accessKey,
                    secretKey: secretKey,
                    bucketName: bucketName
                )
                
                let service = AWSTranscribeService(config: config, chunkingService: AudioFileChunkingService())
                
                // Test AWS connection by calling the test method
                try await service.testConnection()
                
                await MainActor.run {
                    testResult = "✅ AWS connection successful! Your credentials are working."
                    isTesting = false
                }
                
            } catch {
                await MainActor.run {
                    testResult = "❌ Connection failed: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}

struct InstructionRow: View {
    let number: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct AWSSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AWSSettingsView()
    }
} 