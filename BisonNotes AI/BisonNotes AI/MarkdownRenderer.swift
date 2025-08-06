//
//  MarkdownRenderer.swift
//  Audio Journal
//
//  Utility for rendering markdown text in SwiftUI views
//

import SwiftUI
import Foundation

// MARK: - Markdown Renderer

struct MarkdownRenderer {
    
    // MARK: - Public Methods
    
    /// Renders markdown text as an AttributedString for SwiftUI
    static func renderMarkdown(_ markdown: String) -> AttributedString {
        do {
            let attributedString = try AttributedString(markdown: markdown)
            return attributedString
        } catch {
            // Fallback to plain text if markdown parsing fails
            return AttributedString(markdown)
        }
    }
    
    /// Renders markdown text with custom styling
    static func renderMarkdown(_ markdown: String, style: MarkdownStyle = .default) -> AttributedString {
        do {
            var attributedString = try AttributedString(markdown: markdown)
            
            // Apply custom styling
            attributedString = applyCustomStyling(to: attributedString, style: style)
            
            return attributedString
        } catch {
            // Fallback to plain text if markdown parsing fails
            return AttributedString(markdown)
        }
    }
    
    /// Renders markdown text with enhanced list support
    static func renderEnhancedMarkdown(_ markdown: String) -> AttributedString {
        print("🔧 MarkdownRenderer: Starting to render markdown")
        print("📝 Input markdown: \(markdown.prefix(200))...")
        
        // Clean the markdown first
        let cleanedMarkdown = cleanMarkdown(markdown)
        
        do {
            // Try the standard markdown parser first
            let attributedString = try AttributedString(markdown: cleanedMarkdown)
            print("✅ Standard markdown parsing succeeded")
            return attributedString
        } catch {
            print("❌ Standard markdown parsing failed, trying custom formatting: \(error)")
            
            // Fallback to custom formatting
            return createCustomFormattedString(from: cleanedMarkdown)
        }
    }
    

    
    /// Creates a custom formatted string when markdown parsing fails
    private static func createCustomFormattedString(from markdown: String) -> AttributedString {
        var attributedString = AttributedString()
        
        let lines = markdown.components(separatedBy: .newlines)
        
        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.isEmpty {
                // Add paragraph break only if not at the end and not followed by another empty line
                if index < lines.count - 1 {
                    let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if !nextLine.isEmpty {
                        attributedString.append(AttributedString("\n"))
                    }
                }
                continue
            }
            
            // Handle headers with enhanced styling
            if trimmedLine.hasPrefix("### ") {
                let text = String(trimmedLine.dropFirst(4))
                var headerString = AttributedString(text)
                headerString.font = .title3.weight(.semibold)
                headerString.foregroundColor = .primary
                
                // Add a subtle background or border effect
                attributedString.append(AttributedString("\n"))
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n"))
                
                // Add a subtle separator line
                var separatorString = AttributedString("─")
                separatorString.font = .caption
                separatorString.foregroundColor = .secondary
                attributedString.append(separatorString)
                attributedString.append(AttributedString("\n\n"))
                
            } else if trimmedLine.hasPrefix("## ") {
                let text = String(trimmedLine.dropFirst(3))
                var headerString = AttributedString(text)
                headerString.font = .title2.weight(.bold)
                headerString.foregroundColor = .primary
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n\n"))
                
            } else if trimmedLine.hasPrefix("# ") {
                let text = String(trimmedLine.dropFirst(2))
                var headerString = AttributedString(text)
                headerString.font = .title.weight(.bold)
                headerString.foregroundColor = .primary
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n\n"))
                
            } else if trimmedLine.hasPrefix("**") && trimmedLine.hasSuffix("**") && trimmedLine.count > 4 {
                // Bold text
                let text = String(trimmedLine.dropFirst(2).dropLast(2))
                var boldString = AttributedString(text)
                boldString.font = .body.weight(.semibold)
                attributedString.append(boldString)
                attributedString.append(AttributedString("\n\n"))
                
            } else if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
                // Bullet point with enhanced styling
                let text = String(trimmedLine.dropFirst(2))
                var bulletString = AttributedString("• ")
                bulletString.font = .body
                bulletString.foregroundColor = .accentColor
                attributedString.append(bulletString)
                
                var contentString = AttributedString(text)
                contentString.font = .body
                attributedString.append(contentString)
                attributedString.append(AttributedString("\n"))
                
            } else if trimmedLine.matches("^\\d+\\. ") {
                // Numbered list with enhanced styling
                let numberEndIndex = trimmedLine.firstIndex(of: " ") ?? trimmedLine.startIndex
                let number = String(trimmedLine[..<numberEndIndex])
                let text = String(trimmedLine[numberEndIndex...]).trimmingCharacters(in: .whitespaces)
                
                var numberString = AttributedString("\(number). ")
                numberString.font = .body.weight(.medium)
                numberString.foregroundColor = .accentColor
                attributedString.append(numberString)
                
                var contentString = AttributedString(text)
                contentString.font = .body
                attributedString.append(contentString)
                attributedString.append(AttributedString("\n"))
                
            } else {
                // Regular text - handle inline formatting
                let formattedText = processInlineFormatting(trimmedLine)
                attributedString.append(formattedText)
                
                // Add appropriate spacing based on context
                if index < lines.count - 1 {
                    let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if nextLine.isEmpty {
                        // Next line is empty, add paragraph break
                        attributedString.append(AttributedString("\n\n"))
                    } else if nextLine.hasPrefix("- ") || nextLine.hasPrefix("* ") || nextLine.matches("^\\d+\\. ") {
                        // Next line is a list item, add single line break
                        attributedString.append(AttributedString("\n"))
                    } else {
                        // Next line is regular text, add single line break
                        attributedString.append(AttributedString("\n"))
                    }
                }
            }
        }
        
        return attributedString
    }
    
    /// Processes inline formatting like bold and italic text
    private static func processInlineFormatting(_ text: String) -> AttributedString {
        var attributedString = AttributedString()
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            // Look for bold text first (double asterisks)
            if let boldStart = text[currentIndex...].firstIndex(of: "*") {
                let afterFirstAsterisk = text.index(after: boldStart)
                if afterFirstAsterisk < text.endIndex && text[afterFirstAsterisk] == "*" {
                    // Found double asterisk - look for closing double asterisk
                    let afterSecondAsterisk = text.index(after: afterFirstAsterisk)
                    if let boldEnd = text[afterSecondAsterisk...].firstIndex(of: "*") {
                        let afterBoldEnd = text.index(after: boldEnd)
                        if afterBoldEnd < text.endIndex && text[afterBoldEnd] == "*" {
                            // Found closing double asterisk - create bold text
                            let boldText = String(text[afterSecondAsterisk..<boldEnd])
                            var boldString = AttributedString(boldText)
                            boldString.font = .body.weight(.semibold)
                            attributedString.append(boldString)
                            
                            // Move past the closing double asterisk
                            currentIndex = text.index(after: afterBoldEnd)
                            continue
                        }
                    }
                }
            }
            
            // Look for single asterisks for emphasis/italic
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
    
    /// Renders markdown text with minimal preprocessing for better compatibility
    static func renderSimpleMarkdown(_ markdown: String) -> AttributedString {
        do {
            let attributedString = try AttributedString(markdown: markdown)
            return attributedString
        } catch {
            print("❌ Simple markdown parsing failed: \(error)")
            print("📝 Markdown: \(markdown)")
            // Fallback to plain text if markdown parsing fails
            return AttributedString(markdown)
        }
    }
    
    /// Renders AI-generated text with proper line break handling
    static func renderAIGeneratedText(_ text: String) -> AttributedString {
        print("🔧 MarkdownRenderer: Starting to render AI-generated text")
        print("📝 Input text: \(text.prefix(200))...")
        
        // Convert \n escape sequences to proper markdown line breaks
        let processedText = convertAITextWithLineBreaks(text)
        
        do {
            let attributedString = try AttributedString(markdown: processedText)
            print("✅ AI text markdown parsing succeeded")
            return attributedString
        } catch {
            print("❌ AI text markdown parsing failed, using custom formatting: \(error)")
            return createCustomFormattedString(from: processedText)
        }
    }
    
    /// Converts AI text with \n escape sequences to proper markdown
    private static func convertAITextWithLineBreaks(_ text: String) -> String {
        var result = text
        
        // Convert \n escape sequences to actual newlines first
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        
        // Split by newlines to process each line
        let lines = result.components(separatedBy: .newlines)
        var processedLines: [String] = []
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.isEmpty {
                continue
            }
            
            // If line starts with "- " or "* ", it's a bullet point
            if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
                processedLines.append(trimmedLine)
            } else if trimmedLine.matches("^\\d+\\. ") {
                // Numbered list
                processedLines.append(trimmedLine)
            } else if trimmedLine.hasPrefix("**") && trimmedLine.hasSuffix("**") {
                // Bold text as header
                let headerText = String(trimmedLine.dropFirst(2).dropLast(2))
                processedLines.append("## \(headerText)")
            } else {
                // Regular text
                processedLines.append(trimmedLine)
            }
        }
        
        // Join with double newlines to create proper paragraph breaks
        let markdown = processedLines.joined(separator: "\n\n")
        
        print("🔧 Converted AI text to markdown:")
        print(markdown.prefix(300))
        
        return markdown
    }
    
    /// Converts AI text to proper markdown format
    private static func convertAITextToMarkdown(_ text: String) -> String {
        var markdown = text
        
        // First, convert \n escape sequences to actual newlines
        markdown = markdown.replacingOccurrences(of: "\\n", with: "\n")
        
        // Split into lines
        let lines = markdown.components(separatedBy: .newlines)
        var processedLines: [String] = []
        
        for (_, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.isEmpty {
                continue
            }
            
            // Handle bullet points that might be separated by \n
            if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
                processedLines.append(trimmedLine)
            } else if trimmedLine.matches("^\\d+\\. ") {
                processedLines.append(trimmedLine)
            } else if trimmedLine.hasPrefix("**") && trimmedLine.hasSuffix("**") {
                // Bold text - add as header
                let text = String(trimmedLine.dropFirst(2).dropLast(2))
                processedLines.append("## \(text)")
            } else {
                // Regular text
                processedLines.append(trimmedLine)
            }
        }
        
        // Join with proper spacing - use double newlines for paragraph breaks
        let result = processedLines.joined(separator: "\n\n")
        
        print("🔧 Converted AI text to markdown:")
        print(result.prefix(300))
        
        return result
    }
    
    /// Cleans markdown text by removing unwanted formatting
    static func cleanMarkdown(_ markdown: String) -> String {
        var cleaned = markdown
        
        // Convert \n escape sequences to actual newlines first
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        
        // Remove any leading/trailing whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Fix common markdown issues
        // Ensure proper spacing around headers
        cleaned = cleaned.replacingOccurrences(of: "\n#", with: "\n\n#")
        cleaned = cleaned.replacingOccurrences(of: "\n##", with: "\n\n##")
        cleaned = cleaned.replacingOccurrences(of: "\n###", with: "\n\n###")
        
        // Ensure proper spacing around lists
        cleaned = cleaned.replacingOccurrences(of: "\n- ", with: "\n\n- ")
        cleaned = cleaned.replacingOccurrences(of: "\n* ", with: "\n\n* ")
        cleaned = cleaned.replacingOccurrences(of: "\n1. ", with: "\n\n1. ")
        
        // Handle bullet points that are separated by \n in the original text
        // Convert patterns like "text. \n- " to "text.\n\n- "
        cleaned = cleaned.replacingOccurrences(of: "([.!?])\\s*\\n\\s*- ", with: "$1\n\n- ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "([.!?])\\s*\\n\\s*\\* ", with: "$1\n\n* ", options: .regularExpression)
        
        // Handle numbered lists
        cleaned = cleaned.replacingOccurrences(of: "([.!?])\\s*\\n\\s*\\d+\\. ", with: "$1\n\n$2", options: .regularExpression)
        
        // Handle Google AI specific patterns
        // Convert "• " to "- " for consistency
        cleaned = cleaned.replacingOccurrences(of: "• ", with: "- ")
        
        // Ensure proper spacing after headers
        cleaned = cleaned.replacingOccurrences(of: "(### .*?)\\n([^-\\*\\d])", with: "$1\n\n$2", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(## .*?)\\n([^-\\*\\d])", with: "$1\n\n$2", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(# .*?)\\n([^-\\*\\d])", with: "$1\n\n$2", options: .regularExpression)
        
        // Remove excessive newlines (but preserve intentional paragraph breaks)
        cleaned = cleaned.replacingOccurrences(of: "\n{4,}", with: "\n\n", options: .regularExpression)
        
        // Remove excessive spaces
        cleaned = cleaned.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        
        // Trim whitespace again
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
    
    /// Renders Google AI-generated content with enhanced styling
    static func renderGoogleAIContent(_ content: String) -> AttributedString {
        print("🔧 MarkdownRenderer: Starting to render Google AI content")
        print("📝 Input content: \(content.prefix(200))...")
        
        // Clean and preprocess the content
        let cleanedContent = cleanGoogleAIContent(content)
        
        // For Google AI content, prefer the custom formatter to ensure proper bold text handling
        print("🔧 Using custom formatter for Google AI content")
        return createGoogleAICustomFormattedString(from: cleanedContent)
    }
    
    // MARK: - Unified Robust Markdown Renderer
    
    /// Universal robust markdown renderer that handles all AI service formats
    /// Combines the best features from Google AI, enhanced, and standard renderers
    static func renderUnifiedRobustMarkdown(_ content: String, aiService: String = "") -> AttributedString {
        print("🚀 UnifiedMarkdownRenderer: Starting to render content from \(aiService)")
        print("📝 Raw input content: \(content.prefix(300))...")
        
        // Step 1: Comprehensive preprocessing
        let preprocessedContent = comprehensivePreprocessing(content, aiService: aiService)
        print("📝 After preprocessing: \(preprocessedContent.prefix(300))...")
        
        // Use our reliable custom formatter (iOS parser is unreliable)
        print("🎯 Using custom markdown formatter")
        return createUnifiedCustomFormattedString(from: preprocessedContent)
    }
    
    /// Comprehensive preprocessing that handles all AI service formats
    private static func comprehensivePreprocessing(_ content: String, aiService: String) -> String {
        var processed = content
        
        // Step 1: Handle escape sequences and basic cleanup
        processed = processed.replacingOccurrences(of: "\\n", with: "\n")
        processed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Quick check: If content already looks like well-formed markdown, do minimal processing
        let hasValidMarkdown = processed.contains("**") && processed.contains("#") && processed.contains("-")
        if hasValidMarkdown {
            print("🎯 Content appears to be well-formed markdown, applying minimal preprocessing")
            // Only apply basic cleanup
            processed = finalCleanup(processed)
            print("🔧 Minimally preprocessed content: \(processed.prefix(300))")
            return processed
        }
        
        print("🔧 Content needs comprehensive preprocessing")
        
        // Step 2: Fix common bold text issues across all AI services
        processed = fixBoldTextPatterns(processed)
        
        // Step 3: Service-specific preprocessing
        switch aiService.lowercased() {
        case let service where service.contains("google") || service.contains("gemini"):
            processed = preprocessGoogleAIContent(processed)
        case let service where service.contains("openai") || service.contains("gpt"):
            processed = preprocessOpenAIContent(processed)
        case let service where service.contains("bedrock") || service.contains("claude"):
            processed = preprocessBedrockContent(processed)
        case let service where service.contains("ollama"):
            processed = preprocessOllamaContent(processed)
        default:
            processed = preprocessGenericAIContent(processed)
        }
        
        // Step 4: Universal structural fixes
        processed = applyUniversalStructuralFixes(processed)
        
        // Step 5: Final cleanup
        processed = finalCleanup(processed)
        
        print("🔧 Fully preprocessed content: \(processed.prefix(300))")
        return processed
    }
    
    /// Google AI specific preprocessing
    private static func preprocessGoogleAIContent(_ content: String) -> String {
        var processed = content
        
        // Handle Google AI's bullet point format - ensure proper spacing
        processed = processed.replacingOccurrences(of: "• ", with: "- ")
        processed = processed.replacingOccurrences(of: "\n• ", with: "\n- ")
        
        // Fix Google AI's tendency to create unstructured content
        if !processed.contains("\n") {
            processed = aggressivelyRestructureContent(processed)
        }
        
        // Handle Google AI's bold text patterns
        processed = processed.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "**$1**", options: .regularExpression)
        
        return processed
    }
    
    /// OpenAI specific preprocessing
    private static func preprocessOpenAIContent(_ content: String) -> String {
        var processed = content
        
        // OpenAI often uses proper markdown, but may have spacing issues
        processed = processed.replacingOccurrences(of: "\n-", with: "\n\n-")
        processed = processed.replacingOccurrences(of: "\n\\*", with: "\n\n*", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "\n\\d+\\.", with: "\n\n$0", options: .regularExpression)
        
        return processed
    }
    
    /// AWS Bedrock/Claude specific preprocessing
    private static func preprocessBedrockContent(_ content: String) -> String {
        var processed = content
        
        // Bedrock/Claude typically uses good markdown, so minimal preprocessing
        // Only fix spacing around lists after sentences
        processed = processed.replacingOccurrences(of: "([.!?])\\s*\\n\\s*-", with: "$1\n\n-", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "([.!?])\\s*\\n\\s*•", with: "$1\n\n•", options: .regularExpression)
        
        return processed
    }
    
    /// Ollama specific preprocessing
    private static func preprocessOllamaContent(_ content: String) -> String {
        var processed = content
        
        // Ollama models vary, so apply general fixes
        processed = preprocessGenericAIContent(processed)
        
        return processed
    }
    
    /// Generic AI content preprocessing
    private static func preprocessGenericAIContent(_ content: String) -> String {
        var processed = content
        
        // Handle common AI patterns
        processed = processed.replacingOccurrences(of: "([.!?])\\s*\\n\\s*([A-Z])", with: "$1\n\n$2", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "([a-z])([A-Z])(?![*])", with: "$1 $2", options: .regularExpression)
        
        return processed
    }
    
    /// Apply universal structural fixes that work for all services
    private static func applyUniversalStructuralFixes(_ content: String) -> String {
        var processed = content
        
        // Only apply minimal fixes to avoid breaking properly formatted content
        // Handle mixed bullet point styles (normalize to -)
        processed = processed.replacingOccurrences(of: "\\n\\* ", with: "\n- ", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "^\\* ", with: "- ", options: .regularExpression)
        
        return processed
    }
    
    /// Fixes common bold text patterns that different AI engines produce
    private static func fixBoldTextPatterns(_ content: String) -> String {
        var processed = content
        
        print("🔧 Bold text fix - Before: \(processed.prefix(200))...")
        
        // Only apply minimal fixes to avoid breaking valid markdown
        // Fix double asterisks that are properly formed but may have excessive spacing
        // Pattern: ** text ** -> **text** (only if more than one space)
        processed = processed.replacingOccurrences(of: "\\*\\*  +([^*]+?)  +\\*\\*", with: "**$1**", options: .regularExpression)
        
        // Fix case where there are spaces inside the asterisks (very specific pattern)
        // Pattern: * * text * * -> **text** (only exact pattern)
        processed = processed.replacingOccurrences(of: "\\* \\* ([^*]+?) \\* \\*", with: "**$1**", options: .regularExpression)
        
        print("🔧 Bold text fix - After: \(processed.prefix(200))...")
        return processed
    }

    /// Final cleanup pass
    private static func finalCleanup(_ content: String) -> String {
        var processed = content
        
        // Remove excessive newlines (more than 2 consecutive)
        processed = processed.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        
        // Remove excessive spaces (more than single space)
        processed = processed.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        
        // Remove trailing whitespace from lines
        processed = processed.replacingOccurrences(of: " +\\n", with: "\n", options: .regularExpression)
        
        // Final trim
        processed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return processed
    }
    
    /// Creates a unified custom formatted string with the best features from all renderers
    private static func createUnifiedCustomFormattedString(from content: String) -> AttributedString {
        var attributedString = AttributedString()
        
        print("🔧 Custom formatter input: \(content.prefix(200))...")
        let lines = content.components(separatedBy: .newlines)
        print("🔧 Split into \(lines.count) lines")
        
        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.isEmpty {
                // Add paragraph breaks for empty lines
                attributedString.append(AttributedString("\n"))
                continue
            }
            
            // Special handling for lines that contain both text and headers (like "Meeting Summary: ## Title")
            if trimmedLine.contains("##") && !trimmedLine.hasPrefix("##") {
                print("🔧 Processing mixed text/header line: '\(trimmedLine)'")
                // Split on the header marker
                let parts = trimmedLine.components(separatedBy: "##")
                if parts.count >= 2 {
                    // Process the part before the header as regular text
                    let beforeHeader = parts[0].trimmingCharacters(in: .whitespaces)
                    if !beforeHeader.isEmpty {
                        let beforeText = processAdvancedInlineFormatting(beforeHeader)
                        attributedString.append(beforeText)
                        attributedString.append(AttributedString(" "))
                    }
                    
                    // Process the header part
                    let headerText = parts.dropFirst().joined(separator: "##").trimmingCharacters(in: .whitespaces)
                    var headerAttributed = AttributedString(headerText)
                    headerAttributed.font = .title.weight(.bold)
                    headerAttributed.foregroundColor = .primary
                    attributedString.append(headerAttributed)
                    
                    // Add spacing after combined line
                    if index < lines.count - 1 {
                        attributedString.append(AttributedString("\n\n"))
                    }
                    continue
                }
            }
            
            // Enhanced header handling with better typography
            if let headerLevel = getHeaderLevel(trimmedLine) {
                let text = getHeaderText(trimmedLine, level: headerLevel)
                var headerString = AttributedString(text)
                
                switch headerLevel {
                case 1:
                    headerString.font = .largeTitle.weight(.bold)
                    headerString.foregroundColor = .primary
                case 2:
                    headerString.font = .title.weight(.bold)
                    headerString.foregroundColor = .primary
                case 3:
                    headerString.font = .title2.weight(.semibold)
                    headerString.foregroundColor = .primary
                default:
                    headerString.font = .title3.weight(.medium)
                    headerString.foregroundColor = .primary
                }
                
                // Add proper spacing before header
                if !attributedString.characters.isEmpty {
                    attributedString.append(AttributedString("\n\n"))
                }
                
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n"))
                
                // Add visual separator for level 3 headers
                if headerLevel == 3 {
                    var separatorString = AttributedString("─")
                    separatorString.font = .caption
                    separatorString.foregroundColor = .secondary
                    attributedString.append(separatorString)
                    attributedString.append(AttributedString("\n"))
                }
                
                // Add spacing after header
                attributedString.append(AttributedString("\n"))
                
            } else if isListItem(trimmedLine) {
                // Enhanced list handling
                let (listType, content) = parseListItem(trimmedLine)
                
                var bulletString: AttributedString
                switch listType {
                case .bullet:
                    bulletString = AttributedString("• ")
                    bulletString.foregroundColor = .accentColor
                case .numbered(let number):
                    bulletString = AttributedString("\(number). ")
                    bulletString.foregroundColor = .accentColor
                    bulletString.font = .body.weight(.medium)
                }
                
                bulletString.font = .body
                attributedString.append(bulletString)
                
                // Process content with enhanced inline formatting
                let formattedContent = processAdvancedInlineFormatting(content)
                attributedString.append(formattedContent)
                attributedString.append(AttributedString("\n"))
                
            } else {
                // Regular text with advanced inline formatting
                print("🔧 Processing line: '\(trimmedLine.prefix(100))...'")
                let formattedText = processAdvancedInlineFormatting(trimmedLine)
                print("🔧 Formatted result: \(formattedText.characters.count) characters")
                attributedString.append(formattedText)
                
                // Smart spacing based on context - ensure proper line breaks
                if index < lines.count - 1 {
                    let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if nextLine.isEmpty {
                        // Next line is empty, add double line break
                        attributedString.append(AttributedString("\n\n"))
                    } else if isListItem(nextLine) || isHeader(nextLine) {
                        // Next line is special element, add single line break with space
                        attributedString.append(AttributedString("\n\n"))
                    } else {
                        // Next line is regular text, add single line break with space
                        attributedString.append(AttributedString("\n\n"))
                    }
                } else {
                    // Last line, add final line break
                    attributedString.append(AttributedString("\n"))
                }
            }
        }
        
        return attributedString
    }
    
    // MARK: - Advanced Helper Methods
    
    private static func isListItem(_ line: String) -> Bool {
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || line.matches("^\\d+\\. ")
    }
    
    private static func isHeader(_ line: String) -> Bool {
        return line.hasPrefix("#")
    }
    
    private static func getHeaderLevel(_ line: String) -> Int? {
        if line.hasPrefix("### ") { return 3 }
        if line.hasPrefix("## ") { return 2 }
        if line.hasPrefix("# ") { return 1 }
        return nil
    }
    
    private static func getHeaderText(_ line: String, level: Int) -> String {
        let prefixLength = level + 1 // # + space
        return String(line.dropFirst(prefixLength))
    }
    
    private enum ListType {
        case bullet
        case numbered(Int)
    }
    
    private static func parseListItem(_ line: String) -> (ListType, String) {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            return (.bullet, String(line.dropFirst(2)))
        } else if line.matches("^\\d+\\. ") {
            let components = line.components(separatedBy: ". ")
            if let numberString = components.first, let number = Int(numberString) {
                let content = components.dropFirst().joined(separator: ". ")
                return (.numbered(number), content)
            }
        }
        return (.bullet, line)
    }
    
    /// Advanced inline formatting processor that handles complex patterns
    private static func processAdvancedInlineFormatting(_ text: String) -> AttributedString {
        var attributedString = AttributedString()
        var currentIndex = text.startIndex
        
        print("🔧 Inline formatting input: '\(text)'")
        
        // First, preprocess the text to fix any malformed bold patterns
        let preprocessedText = fixInlineBoldPatterns(text)
        print("🔧 After preprocessing: '\(preprocessedText)'")
        
        while currentIndex < preprocessedText.endIndex {
            // Look for bold text (double asterisks) - prioritize this over italic
            if let boldMatch = findBoldMatch(in: preprocessedText, startingAt: currentIndex) {
                print("🔧 Found bold text: '\(boldMatch.content)'")
                
                // Add text before bold
                if boldMatch.range.lowerBound > currentIndex {
                    let beforeText = String(preprocessedText[currentIndex..<boldMatch.range.lowerBound])
                    attributedString.append(AttributedString(beforeText))
                }
                
                // Add bold text (content without the ** markers)
                var boldString = AttributedString(boldMatch.content)
                boldString.font = .body.weight(.bold)
                boldString.foregroundColor = .primary
                attributedString.append(boldString)
                
                currentIndex = boldMatch.range.upperBound
                continue
            }
            
            // Look for italic text (single asterisk) - but avoid conflicts with bold
            if let italicMatch = findItalicMatch(in: preprocessedText, startingAt: currentIndex) {
                print("🔧 Found italic text: '\(italicMatch.content)'")
                
                // Add text before italic
                if italicMatch.range.lowerBound > currentIndex {
                    let beforeText = String(preprocessedText[currentIndex..<italicMatch.range.lowerBound])
                    attributedString.append(AttributedString(beforeText))
                }
                
                // Add italic text (content without the * markers)
                var italicString = AttributedString(italicMatch.content)
                italicString.font = .body.italic()
                attributedString.append(italicString)
                
                currentIndex = italicMatch.range.upperBound
                continue
            }
            
            // No more formatting found - add remaining text
            let remainingText = String(preprocessedText[currentIndex...])
            print("🔧 Adding remaining text: '\(remainingText.prefix(50))...'")
            attributedString.append(AttributedString(remainingText))
            break
        }
        
        return attributedString
    }
    
    /// Fixes inline bold patterns that might be malformed
    private static func fixInlineBoldPatterns(_ text: String) -> String {
        var processed = text
        
        // Handle cases where asterisks are separated by spaces or have inconsistent spacing
        // Pattern: * *text* * -> **text**
        processed = processed.replacingOccurrences(of: "\\* \\*([^*]+?)\\* \\*", with: "**$1**", options: .regularExpression)
        
        // Handle cases where bold text has extra spaces inside
        // Pattern: ** text ** -> **text**
        processed = processed.replacingOccurrences(of: "\\*\\* +([^*]+?) +\\*\\*", with: "**$1**", options: .regularExpression)
        
        // DON'T convert single asterisks to double - that breaks italic formatting!
        
        return processed
    }
    
    private struct FormatMatch {
        let range: Range<String.Index>
        let content: String
    }
    
    private static func findBoldMatch(in text: String, startingAt start: String.Index) -> FormatMatch? {
        // Look for **text** pattern with improved handling
        if let startRange = text[start...].range(of: "**") {
            let afterStart = startRange.upperBound
            // Look for closing ** but avoid matching with empty content
            var searchStart = afterStart
            
            while let endRange = text[searchStart...].range(of: "**") {
                let content = String(text[afterStart..<endRange.lowerBound])
                // Accept content that contains letters/numbers/spaces/punctuation
                if !content.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let fullRange = startRange.lowerBound..<endRange.upperBound
                    return FormatMatch(range: fullRange, content: content)
                }
                // If content is empty or only whitespace, continue searching
                searchStart = endRange.upperBound
                if searchStart >= text.endIndex { break }
            }
        }
        return nil
    }
    
    private static func findItalicMatch(in text: String, startingAt start: String.Index) -> FormatMatch? {
        // Look for *text* pattern (but not ** which is bold)
        var searchStart = start
        while let startIdx = text[searchStart...].firstIndex(of: "*") {
            // Check if it's not part of a ** pattern
            let beforeIdx = startIdx > text.startIndex ? text.index(before: startIdx) : text.startIndex
            let afterIdx = text.index(after: startIdx)
            
            let isPartOfBold = (beforeIdx != text.startIndex && text[beforeIdx] == "*") ||
                              (afterIdx < text.endIndex && text[afterIdx] == "*")
            
            if !isPartOfBold {
                // Look for closing *
                if let endIdx = text[afterIdx...].firstIndex(of: "*") {
                    let afterEndIdx = text.index(after: endIdx)
                    let isEndPartOfBold = afterEndIdx < text.endIndex && text[afterEndIdx] == "*"
                    
                    if !isEndPartOfBold {
                        let content = String(text[afterIdx..<endIdx])
                        if !content.isEmpty {
                            let fullRange = startIdx..<text.index(after: endIdx)
                            return FormatMatch(range: fullRange, content: content)
                        }
                    }
                }
            }
            
            searchStart = text.index(after: startIdx)
            if searchStart >= text.endIndex { break }
        }
        
        return nil
    }
    
    /// Cleans Google AI content for better rendering
    private static func cleanGoogleAIContent(_ content: String) -> String {
        var cleaned = content
        
        // Convert \n escape sequences to actual newlines first
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        
        // Handle unstructured content that comes as a single blob
        cleaned = restructureUnstructuredContent(cleaned)
        
        // If content is still very unstructured (no line breaks), use aggressive restructuring
        if !cleaned.contains("\n") {
            cleaned = aggressivelyRestructureContent(cleaned)
        }
        
        // Handle Google AI specific patterns
        // Convert "• " to "- " for consistency
        cleaned = cleaned.replacingOccurrences(of: "• ", with: "- ")
        
        // Ensure proper spacing around headers
        cleaned = cleaned.replacingOccurrences(of: "\n###", with: "\n\n###")
        cleaned = cleaned.replacingOccurrences(of: "\n##", with: "\n\n##")
        cleaned = cleaned.replacingOccurrences(of: "\n#", with: "\n\n#")
        
        // Ensure proper spacing around bullet points
        cleaned = cleaned.replacingOccurrences(of: "\n- ", with: "\n\n- ")
        cleaned = cleaned.replacingOccurrences(of: "\n* ", with: "\n\n* ")
        
        // Handle patterns where bullet points follow text without proper spacing
        cleaned = cleaned.replacingOccurrences(of: "([.!?])\\s*\\n\\s*- ", with: "$1\n\n- ", options: .regularExpression)
        
        // Remove excessive newlines
        cleaned = cleaned.replacingOccurrences(of: "\n{4,}", with: "\n\n", options: .regularExpression)
        
        // Remove excessive spaces (but be careful not to break formatting)
        cleaned = cleaned.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        
        // Trim whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
    
    /// Restructures unstructured content that comes as a single blob
    private static func restructureUnstructuredContent(_ content: String) -> String {
        var restructured = content
        
        // First, try to identify and fix common patterns in unstructured content
        
        // Fix headers that are missing proper spacing
        restructured = restructured.replacingOccurrences(of: "([^\\n])(## )", with: "$1\n\n$2", options: .regularExpression)
        restructured = restructured.replacingOccurrences(of: "([^\\n])(### )", with: "$1\n\n$2", options: .regularExpression)
        restructured = restructured.replacingOccurrences(of: "([^\\n])(# )", with: "$1\n\n$2", options: .regularExpression)
        
        // Fix bullet points that are missing proper spacing
        restructured = restructured.replacingOccurrences(of: "([.!?])(\\s*)(• )", with: "$1\n\n$3", options: .regularExpression)
        restructured = restructured.replacingOccurrences(of: "([.!?])(\\s*)(- )", with: "$1\n\n$3", options: .regularExpression)
        restructured = restructured.replacingOccurrences(of: "([.!?])(\\s*)(\\* )", with: "$1\n\n$3", options: .regularExpression)
        
        // Add line breaks after sentences that are followed by headers or bullet points
        restructured = restructured.replacingOccurrences(of: "([.!?])(\\s*)([A-Z][a-z]+)", with: "$1\n\n$3", options: .regularExpression)
        
        // Fix common patterns where text runs together (but be careful with bold text)
        restructured = restructured.replacingOccurrences(of: "([a-z])([A-Z])(?![*])", with: "$1 $2", options: .regularExpression)
        
        // Clean up excessive spaces that might have been created
        restructured = restructured.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        
        return restructured
    }
    
    /// Aggressively restructures very unstructured content that comes as a single blob
    private static func aggressivelyRestructureContent(_ content: String) -> String {
        var restructured = content
        
        // If the content has no line breaks at all, it's likely very unstructured
        if !restructured.contains("\n") {
            // Try to identify headers and add line breaks
            restructured = restructured.replacingOccurrences(of: "(## [^\\s]+)", with: "\n\n$1", options: .regularExpression)
            restructured = restructured.replacingOccurrences(of: "(### [^\\s]+)", with: "\n\n$1", options: .regularExpression)
            restructured = restructured.replacingOccurrences(of: "(# [^\\s]+)", with: "\n\n$1", options: .regularExpression)
            
            // Try to identify bullet points and add line breaks
            restructured = restructured.replacingOccurrences(of: "(• [^\\s]+)", with: "\n\n$1", options: .regularExpression)
            restructured = restructured.replacingOccurrences(of: "(- [^\\s]+)", with: "\n\n$1", options: .regularExpression)
            
            // Add line breaks after sentences that end with periods
            restructured = restructured.replacingOccurrences(of: "([.!?])(\\s+)([A-Z])", with: "$1\n\n$3", options: .regularExpression)
            
            // Fix common patterns where text runs together
            restructured = restructured.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        }
        
        return restructured
    }
    
    /// Creates custom formatted string specifically for Google AI content
    private static func createGoogleAICustomFormattedString(from content: String) -> AttributedString {
        var attributedString = AttributedString()
        
        let lines = content.components(separatedBy: .newlines)
        
        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.isEmpty {
                if index < lines.count - 1 {
                    let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if !nextLine.isEmpty {
                        attributedString.append(AttributedString("\n"))
                    }
                }
                continue
            }
            
            // Handle Google AI headers with enhanced styling
            if trimmedLine.hasPrefix("### ") {
                let text = String(trimmedLine.dropFirst(4))
                var headerString = AttributedString(text)
                headerString.font = .title3.weight(.semibold)
                headerString.foregroundColor = .primary
                
                // Add spacing and visual separator
                attributedString.append(AttributedString("\n"))
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n"))
                
                // Add a subtle separator line
                var separatorString = AttributedString("─")
                separatorString.font = .caption
                separatorString.foregroundColor = .secondary
                attributedString.append(separatorString)
                attributedString.append(AttributedString("\n\n"))
                
            } else if trimmedLine.hasPrefix("## ") {
                let text = String(trimmedLine.dropFirst(3))
                var headerString = AttributedString(text)
                headerString.font = .title2.weight(.bold)
                headerString.foregroundColor = .primary
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n\n"))
                
            } else if trimmedLine.hasPrefix("# ") {
                let text = String(trimmedLine.dropFirst(2))
                var headerString = AttributedString(text)
                headerString.font = .title.weight(.bold)
                headerString.foregroundColor = .primary
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n\n"))
                
            } else if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
                // Enhanced bullet points
                let text = String(trimmedLine.dropFirst(2))
                var bulletString = AttributedString("• ")
                bulletString.font = .body
                bulletString.foregroundColor = .accentColor
                attributedString.append(bulletString)
                
                // Process inline formatting for bullet point content
                let formattedContent = processInlineFormatting(text)
                attributedString.append(formattedContent)
                attributedString.append(AttributedString("\n"))
                
            } else {
                // Regular text with enhanced inline formatting
                let formattedText = processInlineFormatting(trimmedLine)
                attributedString.append(formattedText)
                
                // Add appropriate spacing
                if index < lines.count - 1 {
                    let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if nextLine.isEmpty {
                        attributedString.append(AttributedString("\n\n"))
                    } else {
                        attributedString.append(AttributedString("\n"))
                    }
                }
            }
        }
        
        return attributedString
    }
    
    // MARK: - Private Methods
    
    private static func applyCustomStyling(to attributedString: AttributedString, style: MarkdownStyle) -> AttributedString {
        // Apply custom styling based on the style configuration
        // This can be expanded to support different themes
        return attributedString
    }
    
    private static func preprocessMarkdown(_ markdown: String) -> String {
        var processed = markdown
        
        // Remove any leading/trailing whitespace
        processed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ensure proper spacing for headers
        processed = processed.replacingOccurrences(of: "\n#", with: "\n\n#")
        processed = processed.replacingOccurrences(of: "\n##", with: "\n\n##")
        processed = processed.replacingOccurrences(of: "\n###", with: "\n\n###")
        
        // Clean up excessive spaces (but be more careful)
        processed = processed.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        
        // Ensure proper line breaks
        processed = processed.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        
        // Remove any trailing whitespace
        processed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return processed
    }
}

// MARK: - Markdown Style

struct MarkdownStyle {
    let headingColor: Color
    let bodyColor: Color
    let linkColor: Color
    let emphasisColor: Color
    
    static let `default` = MarkdownStyle(
        headingColor: .primary,
        bodyColor: .primary,
        linkColor: .accentColor,
        emphasisColor: .primary
    )
    
    static let dark = MarkdownStyle(
        headingColor: .white,
        bodyColor: .white,
        linkColor: .blue,
        emphasisColor: .white
    )
}

// MARK: - String Extensions

extension String {
    func matches(_ pattern: String) -> Bool {
        return self.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - AttributedString Extensions
// Removed problematic extension that caused infinite recursion

// MARK: - SwiftUI Extensions

extension View {
    /// Displays markdown text with proper rendering
    func markdownText(_ markdown: String, style: MarkdownStyle = .default) -> some View {
        let cleanedMarkdown = MarkdownRenderer.cleanMarkdown(markdown)
        let attributedString = MarkdownRenderer.renderEnhancedMarkdown(cleanedMarkdown)
        
        return Text(attributedString)
            .textSelection(.enabled)
    }
    
    /// Displays markdown text with enhanced formatting
    func enhancedMarkdownText(_ markdown: String) -> some View {
        let cleanedMarkdown = MarkdownRenderer.cleanMarkdown(markdown)
        let attributedString = MarkdownRenderer.renderEnhancedMarkdown(cleanedMarkdown)
        
        return Text(attributedString)
            .textSelection(.enabled)
    }
    
    /// Displays Google AI content with enhanced styling for headers and bullet points
    func googleAIContentText(_ content: String) -> some View {
        let attributedString = MarkdownRenderer.renderGoogleAIContent(content)
        
        return Text(attributedString)
            .textSelection(.enabled)
    }
    
    /// Displays AI content using the unified robust markdown renderer
    func unifiedRobustMarkdownText(_ content: String, aiService: String = "") -> some View {
        let attributedString = MarkdownRenderer.renderUnifiedRobustMarkdown(content, aiService: aiService)
        
        print("📱 Final AttributedString length: \(attributedString.characters.count)")
        print("📱 First 200 characters: \(String(attributedString.characters.prefix(200)))")
        
        return Text(attributedString)
            .textSelection(.enabled)
    }
} 