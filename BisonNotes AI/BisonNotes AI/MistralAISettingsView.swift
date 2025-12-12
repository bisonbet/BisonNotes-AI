//
//  MistralAISettingsView.swift
//  Audio Journal
//
//  Settings view for configuring Mistral AI summarization
//

import SwiftUI
import os.log

struct MistralAISettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("mistralAPIKey") private var apiKey: String = ""
    @AppStorage("mistralBaseURL") private var baseURL: String = "https://api.mistral.ai/v1"
    @AppStorage("mistralModel") private var selectedModel: String = MistralAIModel.mistralMedium2508.rawValue
    @AppStorage("mistralTemperature") private var temperature: Double = 0.1
    @AppStorage("mistralMaxTokens") private var maxTokens: Int = 4096
    @AppStorage("enableMistralAI") private var isEnabled: Bool = false

    @State private var isTestingConnection = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    private let logger = Logger(subsystem: "com.audiojournal.app", category: "MistralAISettings")

    let onConfigurationChanged: () -> Void

    private var selectedModelEnum: MistralAIModel {
        return MistralAIModel(rawValue: selectedModel) ?? .mistralMedium2508
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API Configuration")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.headline)
                        SecureField("Enter your Mistral API key", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Text("Base URL")
                            .font(.headline)
                        TextField("https://api.mistral.ai/v1", text: $baseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        Text("Mistral uses OpenAI-compatible chat endpoints. Keep the default base URL unless you use a gateway.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Model Settings")) {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(MistralAIModel.allCases, id: \.self) { model in
                            HStack {
                                Text(model.displayName)
                                Spacer()
                                Text(model.costTier)
                                    .font(.caption)
                                    .padding(6)
                                    .background(costTierColor(model.costTier).opacity(0.15))
                                    .clipShape(Capsule())
                                    .foregroundColor(costTierColor(model.costTier))
                            }
                            .tag(model.rawValue)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())

                    Text(selectedModelEnum.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    Text("Temperature: \(temperature, specifier: "%.1f")")
                        .font(.headline)
                    Slider(value: $temperature, in: 0...1, step: 0.1)
                        .accentColor(.blue)

                    Text("Max Output Tokens: \(maxTokens)")
                        .font(.headline)
                    Stepper("", value: $maxTokens, in: 512...selectedModelEnum.maxTokens, step: 256)
                        .labelsHidden()

                    Text("Context window: \(selectedModelEnum.contextWindow/1000)K tokens • \(selectedModelEnum.costTier) pricing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Status")) {
                    Toggle("Enable Mistral AI", isOn: $isEnabled)

                    if !apiKey.isEmpty {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Text("✓ Set")
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Text("Not set")
                                .foregroundColor(.red)
                        }
                    }

                    HStack {
                        Text("Model")
                        Spacer()
                        Text(selectedModelEnum.displayName)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button(action: testConnection) {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "network")
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(apiKey.isEmpty || isTestingConnection)
                }
            }
            .navigationTitle("Mistral AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveSettings() }
                        .disabled(apiKey.isEmpty)
                }
            }
            .alert("Connection Test", isPresented: $showingAlert) {
                Button("OK") { }
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func testConnection() {
        isTestingConnection = true

        Task {
            let engine = MistralAIEngine()
            let success = await engine.testConnection()

            await MainActor.run {
                isTestingConnection = false
                alertMessage = success ? "Connection successful!" : "Connection failed. Please verify your API key and base URL."
                showingAlert = true
            }
        }
    }

    private func saveSettings() {
        logger.info("Saving Mistral AI settings")
        logger.info("Model: \(selectedModel)")
        logger.info("Temperature: \(temperature)")
        logger.info("Max Tokens: \(maxTokens)")
        logger.info("Enabled: \(isEnabled)")

        onConfigurationChanged()
        dismiss()
    }

    private func costTierColor(_ tier: String) -> Color {
        switch tier {
        case "Premium":
            return .purple
        case "Standard":
            return .blue
        default:
            return .green
        }
    }
}

#Preview {
    MistralAISettingsView(onConfigurationChanged: {})
}
