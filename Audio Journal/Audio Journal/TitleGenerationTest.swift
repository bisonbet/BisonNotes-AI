import Foundation
import SwiftUI

// MARK: - Title Generation Test

struct TitleGenerationTest: View {
    @State private var testText = "This is a test conversation about project planning and team meetings. We discussed the quarterly budget review and upcoming product launch. The team agreed on the timeline and assigned responsibilities."
    @State private var testResults: [String: String] = [:]
    @State private var isTesting = false
    @State private var showResults = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Title Generation Test")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Testing standardized title generation across all AI engines")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextEditor(text: $testText)
                    .frame(height: 150)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                
                Button(action: runTest) {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(isTesting ? "Testing..." : "Run Title Generation Test")
                    }
                }
                .disabled(isTesting)
                .buttonStyle(.borderedProminent)
                
                if showResults {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(testResults.keys.sorted()), id: \.self) { engine in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(engine)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    Text(testResults[engine] ?? "No result")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .padding(.leading)
                                }
                                .padding()
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                            }
                        }
                        .padding()
                    }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Title Generation Test")
        }
    }
    
    private func runTest() {
        isTesting = true
        testResults.removeAll()
        showResults = false
        
        Task {
            await performTest()
            
            await MainActor.run {
                isTesting = false
                showResults = true
            }
        }
    }
    
    private func performTest() async {
        let engines: [(String, SummarizationEngine)] = [
            ("Ollama", LocalLLMEngine()),
            ("OpenAI", OpenAISummarizationEngine()),
            ("Apple Intelligence", EnhancedAppleIntelligenceEngine()),
            ("Google AI Studio", GoogleAIStudioEngine())
        ]
        
        for (name, engine) in engines {
            do {
                let titles = try await engine.extractTitles(from: testText)
                let result = titles.first?.text ?? "No title generated"
                testResults[name] = result
                print("✅ \(name): \(result)")
            } catch {
                testResults[name] = "Error: \(error.localizedDescription)"
                print("❌ \(name): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Test Engine Factory

// Use existing engines from the codebase
// GoogleAIStudioEngine is already defined in FutureAIEngines.swift

#Preview {
    TitleGenerationTest()
} 