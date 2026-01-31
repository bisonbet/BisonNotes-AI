import SwiftUI
import Textual

enum AIService {
    case googleAI
    case openAI  
    case bedrock
    case ollama
    case appleIntelligence
    case whisper
    case onDevice
    
    var description: String {
        switch self {
        case .googleAI:
            return "google"
        case .openAI:
            return "openai"
        case .bedrock:
            return "bedrock"
        case .ollama:
            return "ollama"
        case .appleIntelligence:
            return "apple"
        case .whisper:
            return "whisper"
        case .onDevice:
            return "on-device"
        }
    }
    
    /// Maps AI engine and model strings to the appropriate AIService
    static func from(aiEngine: String, aiModel: String) -> AIService {
        let engineLower = aiEngine.lowercased()
        let modelLower = aiModel.lowercased()
        
        if engineLower.contains("google") || modelLower.contains("gemini") {
            return .googleAI
        } else if engineLower.contains("openai") || modelLower.contains("gpt") {
            return .openAI
        } else if engineLower.contains("bedrock") || modelLower.contains("claude") || engineLower.contains("aws") {
            return .bedrock
        } else if engineLower.contains("ollama") {
            return .ollama
        } else if engineLower.contains("apple") || modelLower.contains("intelligence") {
            return .appleIntelligence
        } else if engineLower.contains("whisper") {
            return .whisper
        } else if engineLower.contains("device") || modelLower.contains("gemma") || modelLower.contains("phi") || modelLower.contains("qwen") || modelLower.contains("llama") || modelLower.contains("mistral") || modelLower.contains("olmo") || modelLower.contains("alpaca") {
            return .onDevice
        } else {
            // Default to bedrock for unknown services
            return .bedrock
        }
    }
}

struct AITextView: View {
    let text: String
    let aiService: AIService
    
    init(text: String, aiService: AIService = .googleAI) {
        self.text = text
        self.aiService = aiService
    }
    
    var body: some View {
        // Use Textual with our text cleaning pipeline and emoji support
        let cleanedText = cleanTextForMarkdown(text)

        StructuredText(
            markdown: cleanedText,
            baseURL: nil,
            syntaxExtensions: []
        )
        .textual.textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    /// Clean text using simplified robust cleaning for Textual markdown rendering
    private func cleanTextForMarkdown(_ text: String) -> String {
        var cleaned = text

        // Step 1: Sanitize encoding issues (Unicode replacement chars, smart quotes, etc.)
        cleaned = cleaned.sanitizedForDisplay()

        // Step 2: Normalize line endings and escape sequences
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\r", with: "\n")

        // Step 3: Remove JSON wrappers
        cleaned = cleaned.replacingOccurrences(of: "^\"summary\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^\"content\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^\"text\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\"\\s*$", with: "", options: .regularExpression)

        // Step 4: Basic spacing normalization
        cleaned = cleaned.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        #if DEBUG
        print("🔍 Textual Input Debug:")
        print("Original length: \(text.count)")
        print("Cleaned length: \(cleaned.count)")
        print("First 200 chars: \(cleaned.prefix(200))")
        #endif

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
}

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            Text("Textual Markdown Renderer Tests")
                .font(.title2)
                .fontWeight(.bold)

            Divider()

            Text("Emoji Support Test:")
                .font(.headline)

            AITextView(text: "### Summary with Emoji\n\n:checkmark: Task completed successfully\n:warning: Important note to review\n:info: Additional information\n:rocket: Quick start guide\n:lightbulb: Helpful tips\n:star: Key highlights", aiService: .googleAI)

            Divider()
            
            Text("Complex Headers Test:")
                .font(.headline)
            
            AITextView(text: "### Product Overview\n\nThe company offers an AI-powered tutoring platform.\n\n#### Key Features\n\n• Personalized tutoring for students\n• Concurrent seating model", aiService: .googleAI)
            
            Divider()
            
            Text("Mixed List Types Test:")
                .font(.headline)
            
            AITextView(text: "### Primary Action Items\n\n• Tim to provide list of suspended accounts\n• Confirm deletion with Jack\n• Review MOU language for data deletion\n\n1. Create sample account for testing\n2. Review storage quotas\n3. Implement notification processes", aiService: .googleAI)
            
            Divider()
            
            Text("Complex Nested Content Test:")
                .font(.headline)
            
            AITextView(text: "## Market and Political Dynamics\n\n• Federal Reserve Chair **Jerome Powell** discussed potential interest rate cuts\n• Stock market surged with Dow rising over 800 points\n• Political tensions emerged around Federal Reserve governance\n\n### Key Economic Insights\n\n• Investors looking for positive economic signals\n• Concerns about political interference in independent institutions\n• Discussions about inflation, employment, and market confidence\n\n### Notable Political Developments\n\n• President Trump threatening to fire Federal Reserve Governor **Lisa Cook**\n• Debates about immigrant labor's economic importance", aiService: .googleAI)
            
            Divider()
            
            Text("Bold Headers & JSON Cleanup Test:")
                .font(.headline)
            
            AITextView(text: "\"summary\": \"**Storage and Account Management Highlights**\n\n• Retirees will retain **5GB storage**\n• Data deletion and account management for alumni\n• Google storage quotas and notification processes\n• Suspended account cleanup strategy\"", aiService: .googleAI)
        }
        .padding()
    }
} 
