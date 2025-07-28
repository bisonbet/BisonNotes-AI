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
    
    /// Renders markdown text with enhanced formatting support
    static func renderEnhancedMarkdown(_ markdown: String) -> AttributedString {
        let processedMarkdown = preprocessMarkdown(markdown)
        
        do {
            let attributedString = try AttributedString(markdown: processedMarkdown)
            return attributedString
        } catch {
            // Fallback to plain text if markdown parsing fails
            return AttributedString(markdown)
        }
    }
    
    /// Cleans markdown text by removing unwanted formatting
    static func cleanMarkdown(_ markdown: String) -> String {
        var cleaned = markdown
        
        // Remove excessive newlines
        cleaned = cleaned.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        
        // Remove excessive spaces
        cleaned = cleaned.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        
        // Trim whitespace
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
        
        // Ensure proper spacing for bullet points
        processed = processed.replacingOccurrences(of: "\n- ", with: "\n\n- ")
        processed = processed.replacingOccurrences(of: "\n* ", with: "\n\n* ")
        processed = processed.replacingOccurrences(of: "\n+ ", with: "\n\n+ ")
        
        // Ensure proper spacing for numbered lists
        processed = processed.replacingOccurrences(of: "\n\\d+\\. ", with: "\n\n$0", options: .regularExpression)
        
        // Ensure proper spacing for headers
        processed = processed.replacingOccurrences(of: "\n#", with: "\n\n#")
        processed = processed.replacingOccurrences(of: "\n##", with: "\n\n##")
        processed = processed.replacingOccurrences(of: "\n###", with: "\n\n###")
        
        // Fix bold formatting - ensure proper spacing around **text**
        processed = processed.replacingOccurrences(of: "\\*\\*\\s+", with: "**", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "\\s+\\*\\*", with: "**", options: .regularExpression)
        
        // Fix italic formatting - ensure proper spacing around *text*
        processed = processed.replacingOccurrences(of: "\\*\\s+", with: "*", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "\\s+\\*", with: "*", options: .regularExpression)
        
        // Ensure bullet points are properly formatted with single space
        processed = processed.replacingOccurrences(of: "^-\\s+", with: "- ", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "^\\*\\s+", with: "* ", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "^\\+\\s+", with: "+ ", options: .regularExpression)
        
        // Fix common issues with bullet points not being recognized
        processed = processed.replacingOccurrences(of: "^-\\s*", with: "- ", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "^\\*\\s*", with: "* ", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "^\\+\\s*", with: "+ ", options: .regularExpression)
        
        // Ensure proper spacing around bold and italic text
        processed = processed.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: " **$1** ", options: .regularExpression)
        processed = processed.replacingOccurrences(of: "\\*(.*?)\\*", with: " *$1* ", options: .regularExpression)
        
        // Clean up excessive spaces
        processed = processed.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        
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