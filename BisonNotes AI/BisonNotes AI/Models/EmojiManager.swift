//
//  EmojiManager.swift
//  BisonNotes AI
//
//  Created by Claude Code on 2025-01-21.
//  Manages custom emoji configuration for Textual markdown rendering
//

import Foundation
import Textual

/// Manages custom emoji configuration for Textual's markdown rendering
/// Provides a centralized emoji set for AI-generated content with :shortcode: syntax
struct EmojiManager {
    static let shared = EmojiManager()

    /// Define emoji set for Textual using bundle resource URLs
    /// Each emoji is loaded from PNG assets exported from SF Symbols
    var emojiSet: Set<Emoji> {
        let bundle = Bundle.main
        var emojis: Set<Emoji> = []

        // Helper to safely create emoji with resource URL
        func addEmoji(shortcode: String, resource: String) {
            if let url = bundle.url(forResource: resource, withExtension: "png") {
                emojis.insert(Emoji(shortcode: shortcode, url: url))
            } else {
                #if DEBUG
                print("⚠️ EmojiManager: Failed to load emoji resource '\(resource).png' for shortcode ':\(shortcode):'")
                #endif
            }
        }

        // Register all available emoji
        addEmoji(shortcode: "checkmark", resource: "emoji-checkmark")
        addEmoji(shortcode: "warning", resource: "emoji-warning")
        addEmoji(shortcode: "info", resource: "emoji-info")
        addEmoji(shortcode: "rocket", resource: "emoji-rocket")
        addEmoji(shortcode: "lightbulb", resource: "emoji-lightbulb")
        addEmoji(shortcode: "chart", resource: "emoji-chart")
        addEmoji(shortcode: "speaker", resource: "emoji-speaker")
        addEmoji(shortcode: "brain", resource: "emoji-brain")
        addEmoji(shortcode: "star", resource: "emoji-star")

        #if DEBUG
        print("✅ EmojiManager: Loaded \(emojis.count) emoji shortcodes")
        #endif

        return emojis
    }

    /// Get a specific emoji by shortcode
    /// - Parameter shortcode: The emoji shortcode (without colons, e.g., "checkmark")
    /// - Returns: The Emoji object if found, nil otherwise
    func emoji(for shortcode: String) -> Emoji? {
        return emojiSet.first { $0.shortcode == shortcode }
    }

    /// Get all available shortcodes
    var availableShortcodes: [String] {
        return emojiSet.map { $0.shortcode }.sorted()
    }
}

// MARK: - Usage Examples
/*
 Usage in AITextView:

 StructuredText(markdown: cleanedText, baseURL: nil, syntaxExtensions: [])
 (Custom emoji syntax extensions are not currently used; Textual expects [AttributedStringMarkdownParser.SyntaxExtension].)

 AI engines can include emoji in summaries like:

 ":checkmark: Task completed successfully"
 ":warning: Important note to review"
 ":info: Additional information available"
 ":rocket: Quick start guide"
 ":lightbulb: Tips and suggestions"
 ":chart: Analytics and metrics"
 ":speaker: Audio-related content"
 ":brain: AI-generated insights"
 ":star: Highlighted items"
 */
