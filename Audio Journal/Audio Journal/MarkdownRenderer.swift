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
                // Add paragraph break only if not at the end
                if index < lines.count - 1 {
                    attributedString.append(AttributedString("\n"))
                }
                continue
            }
            
            // Handle headers
            if trimmedLine.hasPrefix("### ") {
                let text = String(trimmedLine.dropFirst(4))
                var headerString = AttributedString(text)
                headerString.font = .headline
                headerString.foregroundColor = .primary
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n\n"))
            } else if trimmedLine.hasPrefix("## ") {
                let text = String(trimmedLine.dropFirst(3))
                var headerString = AttributedString(text)
                headerString.font = .title3
                headerString.foregroundColor = .primary
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n\n"))
            } else if trimmedLine.hasPrefix("# ") {
                let text = String(trimmedLine.dropFirst(2))
                var headerString = AttributedString(text)
                headerString.font = .title2
                headerString.foregroundColor = .primary
                attributedString.append(headerString)
                attributedString.append(AttributedString("\n\n"))
            } else if trimmedLine.hasPrefix("**") && trimmedLine.hasSuffix("**") && trimmedLine.count > 4 {
                // Bold text
                let text = String(trimmedLine.dropFirst(2).dropLast(2))
                var boldString = AttributedString(text)
                boldString.font = .body.bold()
                attributedString.append(boldString)
                attributedString.append(AttributedString("\n\n"))
            } else if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
                // Bullet point
                let text = String(trimmedLine.dropFirst(2))
                attributedString.append(AttributedString("• \(text)"))
                attributedString.append(AttributedString("\n"))
            } else if trimmedLine.matches("^\\d+\\. ") {
                // Numbered list
                attributedString.append(AttributedString(trimmedLine))
                attributedString.append(AttributedString("\n"))
            } else {
                // Regular text - handle inline formatting
                let formattedText = processInlineFormatting(trimmedLine)
                attributedString.append(formattedText)
                attributedString.append(AttributedString("\n"))
            }
        }
        
        return attributedString
    }
    
    /// Processes inline formatting like bold and italic text
    private static func processInlineFormatting(_ text: String) -> AttributedString {
        // For now, just return the text as-is to avoid complex index manipulation
        // The standard markdown parser should handle most inline formatting
        return AttributedString(text)
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
    
    /// Cleans markdown text by removing unwanted formatting
    static func cleanMarkdown(_ markdown: String) -> String {
        var cleaned = markdown
        
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
        
        // Remove excessive newlines
        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        
        // Remove excessive spaces
        cleaned = cleaned.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        
        // Trim whitespace again
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
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
} 