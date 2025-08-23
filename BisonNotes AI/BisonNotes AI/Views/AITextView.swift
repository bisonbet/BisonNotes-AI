import SwiftUI
import MarkdownUI

enum AIService {
    case googleAI
    case openAI  
    case bedrock
    case ollama
    case appleIntelligence
    case whisper
    
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
        }
    }
    
    /// Maps an AI method string to the appropriate AIService
    static func from(aiMethod: String) -> AIService {
        let lowercased = aiMethod.lowercased()
        
        if lowercased.contains("google") || lowercased.contains("gemini") {
            return .googleAI
        } else if lowercased.contains("openai") || lowercased.contains("gpt") {
            return .openAI
        } else if lowercased.contains("bedrock") || lowercased.contains("claude") {
            return .bedrock
        } else if lowercased.contains("ollama") {
            return .ollama
        } else if lowercased.contains("apple") || lowercased.contains("intelligence") {
            return .appleIntelligence
        } else if lowercased.contains("whisper") {
            return .whisper
        } else {
            // Default to standard processor for unknown services
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
        // Use MarkdownUI with our text cleaning pipeline
        let cleanedText = cleanTextForMarkdown(text)
        
        Markdown(cleanedText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    /// Clean text using simplified robust cleaning for MarkdownUI
    private func cleanTextForMarkdown(_ text: String) -> String {
        var cleaned = text
        
        // Step 1: Normalize line endings and escape sequences
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\r", with: "\n")
        
        // Step 2: Remove JSON wrappers
        cleaned = cleaned.replacingOccurrences(of: "^\"summary\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^\"content\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^\"text\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\"\\s*$", with: "", options: .regularExpression)
        
        // Step 3: Basic spacing normalization
        cleaned = cleaned.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        
        #if DEBUG
        print("🔍 MarkdownUI Input Debug:")
        print("Original length: \\(text.count)")
        print("Cleaned length: \\(cleaned.count)")
        print("First 200 chars: \\(cleaned.prefix(200))")
        #endif
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
}

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            Text("Enhanced Markdown Renderer Tests")
                .font(.title2)
                .fontWeight(.bold)
            
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