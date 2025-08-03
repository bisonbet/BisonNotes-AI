import SwiftUI

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
        // Use the unified robust markdown renderer for all AI services
        unifiedRobustMarkdownText(text, aiService: aiService.description)
            .lineSpacing(4)
    }
    
    // Fallback to original custom rendering if needed
    private var fallbackView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(processText(), id: \.self) { line in
                if isBulletPoint(line) {
                    // Bullet point
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                            .foregroundColor(.primary)
                        
                        Text(formatBoldText(extractBulletText(line)))
                            .font(.body)
                            .multilineTextAlignment(.leading)
                    }
                } else if line.matches("^\\d+\\. ") {
                    // Numbered list
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(line.prefix(while: { $0.isNumber }))")
                            .font(.body)
                            .foregroundColor(.primary)
                        
                        Text(formatBoldText(String(line.dropFirst(line.firstIndex(of: " ")?.utf16Offset(in: line) ?? 0))))
                            .font(.body)
                            .multilineTextAlignment(.leading)
                    }
                } else if isHeader(line) {
                    // Header
                    Text(formatBoldText(extractHeaderText(line)))
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .padding(.top, 8)
                } else {
                    // Regular text
                    Text(formatBoldText(line))
                        .font(.body)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }
    
    private func processText() -> [String] {
        // Convert \n escape sequences to actual newlines
        let processedText = text.replacingOccurrences(of: "\\n", with: "\n")
        
        // Clean up common formatting issues and remove JSON artifacts
        let cleanedText = processedText
            .replacingOccurrences(of: "• ", with: "* ")  // Standardize bullet points
            .replacingOccurrences(of: "  ", with: " ")   // Remove double spaces
            .replacingOccurrences(of: "\"summary\":", with: "")  // Remove JSON field names
            .replacingOccurrences(of: "\"summary\" :", with: "")  // Remove JSON field names with spaces
            .replacingOccurrences(of: "\"summary\"", with: "")    // Remove JSON field names without colon
        
        // Split by newlines and filter out empty lines and JSON artifacts
        let lines = cleanedText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && 
                     !$0.contains("{") && 
                     !$0.contains("}") && 
                     !$0.contains("[") && 
                     !$0.contains("]") &&
                     !$0.contains("\"tasks\"") &&
                     !$0.contains("\"reminders\"") &&
                     !$0.contains("\"titles\"") &&
                     !$0.contains("\"summary\"") }
        
        return lines
    }
    
    private func isBulletPoint(_ line: String) -> Bool {
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
    }
    
    private func extractBulletText(_ line: String) -> String {
        if line.hasPrefix("- ") {
            return String(line.dropFirst(2))
        } else if line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        } else if line.hasPrefix("• ") {
            return String(line.dropFirst(2))
        }
        return line
    }
    
    private func isHeader(_ line: String) -> Bool {
        return line.hasPrefix("## ") || line.hasPrefix("# ") || 
               (line.hasPrefix("**") && line.hasSuffix("**"))
    }
    
    private func extractHeaderText(_ line: String) -> String {
        if line.hasPrefix("## ") {
            return String(line.dropFirst(3))
        } else if line.hasPrefix("# ") {
            return String(line.dropFirst(2))
        } else if line.hasPrefix("**") && line.hasSuffix("**") {
            return String(line.dropFirst(2).dropLast(2))
        }
        return line
    }
    
    private func formatBoldText(_ text: String) -> AttributedString {
        var attributedString = AttributedString()
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            // Look for asterisks for emphasis/italic
            if let asteriskStart = text[currentIndex...].firstIndex(of: "*") {
                // Add text before the asterisk
                if asteriskStart > currentIndex {
                    let beforeText = String(text[currentIndex..<asteriskStart])
                    attributedString.append(AttributedString(beforeText))
                }
                
                // Look for the closing asterisk
                let afterAsterisk = text.index(after: asteriskStart)
                if let asteriskEnd = text[afterAsterisk...].firstIndex(of: "*") {
                    // Found matching asterisks - create italic text
                    let italicText = String(text[afterAsterisk..<asteriskEnd])
                    var italicString = AttributedString(italicText)
                    italicString.font = .body.italic()
                    attributedString.append(italicString)
                    
                    // Move past the closing asterisk
                    currentIndex = text.index(after: asteriskEnd)
                } else {
                    // No closing asterisk found - treat as regular text
                    attributedString.append(AttributedString("*"))
                    currentIndex = text.index(after: asteriskStart)
                }
            } else {
                // No more asterisks - add remaining text
                let remainingText = String(text[currentIndex...])
                attributedString.append(AttributedString(remainingText))
                break
            }
        }
        
        return attributedString
    }
}

#Preview {
    AITextView(text: "- **President Trump** is in Scotland, meeting with **Ursula von der Leyen** and **Keir Starmer**, leveraging his **Scottish heritage** and **royal admiration** to foster diplomatic ties.  \\n- **Anti-Trump protests** have erupted in multiple UK cities amid his visit.  \\n- **Secretary of State Marco Rubio** condemned **Hong Kong's arrest warrants** targeting **US-based activists**, accusing the government of eroding autonomy and threatening **American citizens**.", aiService: .googleAI)
        .padding()
} 