//
//  OnDeviceLLMTemplate.swift
//  BisonNotes AI
//
//  Prompt formatting templates for on-device LLM inference
//  Adapted from OLMoE.swift project
//

import Foundation

// MARK: - Template Structure

/// A structure that defines how to format prompts for different LLM architectures
public struct LLMTemplate {
    /// Represents prefix and suffix text to wrap around different message types
    public typealias Attachment = (prefix: String, suffix: String)

    /// Formatting for system messages
    public let system: Attachment

    /// Formatting for user messages
    public let user: Attachment

    /// Formatting for bot/assistant messages
    public let bot: Attachment

    /// Optional system prompt to set context
    public let systemPrompt: String?

    /// Sequences that indicate the end of the model's response
    public let stopSequences: [String]

    /// Legacy accessor for the first stop sequence
    public var stopSequence: String? { stopSequences.first }

    /// Text to prepend to the entire prompt
    public let prefix: String

    /// Whether to drop the last character of the bot prefix
    public let shouldDropLast: Bool

    // MARK: - Initialization

    public init(
        prefix: String = "",
        system: Attachment? = nil,
        user: Attachment? = nil,
        bot: Attachment? = nil,
        stopSequence: String? = nil,
        stopSequences: [String] = [],
        systemPrompt: String?,
        shouldDropLast: Bool = false
    ) {
        self.system = system ?? ("", "")
        self.user = user ?? ("", "")
        self.bot = bot ?? ("", "")

        var sequences = stopSequences
        if let single = stopSequence, !sequences.contains(single) {
            sequences.insert(single, at: 0)
        }
        self.stopSequences = sequences

        self.systemPrompt = systemPrompt
        self.prefix = prefix
        self.shouldDropLast = shouldDropLast
    }

    // MARK: - Preprocessing

    /// Formats input into model-ready prompt (single-shot, no history for summarization)
    public func formatPrompt(_ input: String) -> String {
        var processed = prefix

        if let systemPrompt = systemPrompt {
            processed += "\(system.prefix)\(systemPrompt)\(system.suffix)"
        }

        processed += "\(user.prefix)\(input)\(user.suffix)"

        if shouldDropLast {
            processed += String(bot.prefix.dropLast())
        } else {
            processed += bot.prefix
        }

        return processed
    }

    /// Legacy preprocess closure for compatibility with LLM class
    public var preprocess: (_ input: String, _ history: [LLMChat], _ llmInstance: OnDeviceLLM) -> String {
        return { [self] input, history, llmInstance in
            // For summarization, we don't use history - single shot inference
            if llmInstance.savedState != nil {
                var processed = prefix
                processed += "\(user.prefix)\(input)\(user.suffix)"
                processed += bot.prefix
                return processed
            } else {
                return formatPrompt(input)
            }
        }
    }
}

// MARK: - Predefined Templates

extension LLMTemplate {

    // MARK: - ChatML Format (Common standard, works with many models)

    /// ChatML format - widely supported by many models
    public static func chatML(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            system: ("<|im_start|>system\n", "<|im_end|>\n"),
            user: ("<|im_start|>user\n", "<|im_end|>\n"),
            bot: ("<|im_start|>assistant\n", "<|im_end|>\n"),
            stopSequence: "<|im_end|>",
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Phi-3 Format (Microsoft)

    /// Phi-3 format for Microsoft Phi models
    public static func phi3(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            system: ("<|system|>\n", "<|end|>\n"),
            user: ("<|user|>\n", "<|end|>\n"),
            bot: ("<|assistant|>\n", "<|end|>\n"),
            stopSequence: "<|end|>",
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Llama Format

    /// Llama/Llama2 format
    public static func llama(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            prefix: "[INST] ",
            system: ("<<SYS>>\n", "\n<</SYS>>\n\n"),
            user: ("", " [/INST]"),
            bot: (" ", "</s><s>[INST] "),
            stopSequence: "</s>",
            systemPrompt: systemPrompt,
            shouldDropLast: true
        )
    }

    // MARK: - Llama 3 Format

    /// Llama 3 format with updated tokens
    public static func llama3(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            prefix: "<|begin_of_text|>",
            system: ("<|start_header_id|>system<|end_header_id|>\n\n", "<|eot_id|>"),
            user: ("<|start_header_id|>user<|end_header_id|>\n\n", "<|eot_id|>"),
            bot: ("<|start_header_id|>assistant<|end_header_id|>\n\n", "<|eot_id|>"),
            stopSequence: "<|eot_id|>",
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Mistral Format

    /// Mistral format
    public static let mistral = LLMTemplate(
        user: ("[INST] ", " [/INST]"),
        bot: ("", "</s> "),
        stopSequence: "</s>",
        systemPrompt: nil
    )

    // MARK: - Alpaca Format

    /// Alpaca format for instruction-tuned models
    public static func alpaca(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            system: ("", "\n\n"),
            user: ("### Instruction:\n", "\n\n"),
            bot: ("### Response:\n", "\n\n"),
            stopSequence: "###",
            systemPrompt: systemPrompt
        )
    }

    // MARK: - OLMoE Format

    /// OLMoE format (AI2's model)
    public static func olmoe(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            prefix: "<|endoftext|>",
            system: ("<|system|>\n", "\n"),
            user: ("<|user|>\n", "\n"),
            bot: ("<|assistant|>\n", "\n"),
            stopSequence: "<|endoftext|>",
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Qwen Format

    /// Qwen format for Alibaba's models
    public static func qwen(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            system: ("<|im_start|>system\n", "<|im_end|>\n"),
            user: ("<|im_start|>user\n", "<|im_end|>\n"),
            bot: ("<|im_start|>assistant\n", "<|im_end|>\n"),
            stopSequences: ["<|im_end|>", "<|endoftext|>"],
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Qwen3 Format

    /// Qwen3 format for Alibaba's Qwen3 models (similar to ChatML but with specific handling)
    public static func qwen3(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            system: ("<|im_start|>system\n", "<|im_end|>\n"),
            user: ("<|im_start|>user\n", "<|im_end|>\n"),
            bot: ("<|im_start|>assistant\n", "<|im_end|>\n"),
            stopSequences: ["<|im_end|>", "<|endoftext|>"],
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Gemma 3 Format

    /// Gemma 3 format for Google's Gemma 3 models
    public static func gemma3(_ systemPrompt: String? = nil) -> LLMTemplate {
        // Gemma 3 uses a specific format with <start_of_turn> and <end_of_turn> markers
        let systemText = systemPrompt.map { "<start_of_turn>user\n\($0)<end_of_turn>\n" } ?? ""
        return LLMTemplate(
            prefix: systemText,
            system: ("", ""),  // System is included in prefix
            user: ("<start_of_turn>user\n", "<end_of_turn>\n"),
            bot: ("<start_of_turn>model\n", "<end_of_turn>\n"),
            stopSequences: ["<end_of_turn>", "<eos>"],
            systemPrompt: nil  // Already included in prefix
        )
    }

    // MARK: - Generic/Simple Format

    /// Simple format for models that don't need special tokens
    public static func simple(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            system: ("System: ", "\n\n"),
            user: ("User: ", "\n\n"),
            bot: ("Assistant: ", "\n\n"),
            stopSequences: ["User:", "System:", "\n\n\n"],
            systemPrompt: systemPrompt
        )
    }

    // MARK: - LFM Format (Liquid AI)

    /// LFM 2.5 format with extended stop sequences for Liquid AI models
    /// Includes tool-calling tokens and additional stop markers to prevent hallucinated tokens
    public static func lfm(_ systemPrompt: String? = nil) -> LLMTemplate {
        return LLMTemplate(
            prefix: "<|startoftext|>",
            system: ("<|im_start|>system\n", "<|im_end|>\n"),
            user: ("<|im_start|>user\n", "<|im_end|>\n"),
            bot: ("<|im_start|>assistant\n", "<|im_end|>\n"),
            stopSequences: [
                "<|im_end|>",
                "<|endoftext|>",
                "<|tool_call_start|>",
                "<|tool_call_end|>",
                "<|end",           // Catch hallucinated "<|end_of_*" patterns
                "<| end",          // Catch malformed "<| end_of_*" patterns
                "\n\nUser:",       // Prevent model from generating new turns
                "\n\nuser:",
                "\n\n<|im_start|>" // Prevent model from starting new message
            ],
            systemPrompt: systemPrompt
        )
    }
}

// MARK: - Summarization System Prompts

extension LLMTemplate {

    /// System prompt for generating summaries from transcripts
    public static let summarizationSystemPrompt = """
You are an expert summarizer. Your task is to create clear, well-structured summaries of transcribed audio content.

Guidelines:
- Use proper Markdown formatting with headers, bullet points, and emphasis
- Focus on key points, decisions, and important information
- Organize content logically with clear sections
- Be concise but comprehensive
- Preserve important names, dates, and specific details
- Use **bold** for key terms and *italic* for emphasis
"""

    /// System prompt optimized for LFM models to prevent hallucinated tokens
    public static let lfmSummarizationSystemPrompt = """
You are a helpful assistant trained by Liquid AI. Your task is to create clear, well-structured summaries of transcribed audio content.

Guidelines:
- Use proper Markdown formatting with headers, bullet points, and emphasis
- Focus on key points, decisions, and important information
- Organize content logically with clear sections
- Be concise but comprehensive
- Preserve important names, dates, and specific details
- Use **bold** for key terms and *italic* for emphasis
- End your response naturally when finished - do not add closing markers or signatures
"""

    /// System prompt for extracting tasks from transcripts
    public static let taskExtractionSystemPrompt = """
You are a task extraction specialist. Analyze the transcript and identify actionable tasks.

Guidelines:
- Extract only personal, actionable tasks mentioned by the speaker
- Focus on specific action items, to-dos, and commitments
- Avoid tasks related to news, celebrities, or general world events
- Include deadlines or timeframes if mentioned
- Format each task as a clear, actionable item
"""

    /// System prompt for extracting reminders from transcripts
    public static let reminderExtractionSystemPrompt = """
You are a reminder extraction specialist. Identify time-sensitive items from the transcript.

Guidelines:
- Extract personal appointments, deadlines, and scheduled events
- Include specific dates, times, or relative timeframes
- Focus on items that directly affect the speaker
- Avoid general news events or public happenings
- Format each reminder with the time reference clearly stated
"""

    /// System prompt for complete transcript processing
    public static let completeProcessingSystemPrompt = """
You are an AI assistant specialized in processing audio transcripts. Analyze the content and provide:

1. A comprehensive summary using Markdown formatting
2. Actionable tasks (personal items only, not news or public events)
3. Time-sensitive reminders (personal appointments and deadlines)
4. Suggested titles for the recording

Be thorough but concise. Focus on information that is personally relevant to the speaker.
"""
}
