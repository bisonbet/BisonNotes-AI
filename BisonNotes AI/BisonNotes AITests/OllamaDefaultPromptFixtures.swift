// Generated from the v3.0 (pre-Summary Prompt) Ollama prompt builders for the
// Default preset. CLAUDE.md: "The Default preset is byte-identical to the
// pre-composer prompts." Regenerate only for an intended Default change.

enum OllamaDefaultPromptFixtures {
    /// The transcript every fixture was built from.
    static let transcript = "Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday."

    static let robustSummary = #"""
<INSTRUCTIONS>
You are a professional AI assistant specialized in analyzing and summarizing conversations, meetings, and transcripts. Your goal is to create well-structured summaries at the requested detail level.

SUMMARY DETAIL REQUIREMENT:
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.

CRITICAL REQUIREMENTS:
1. Focus on main points, key decisions, important information, and actionable items
2. Use proper Markdown formatting throughout your response
3. Structure your response logically with clear sections
4. Match the selected detail level without padding or repeating the transcript
5. Maintain professional, clear language

MARKDOWN FORMATTING RULES:
- Use ## for main section headers (e.g., ## Key Points, ## Decisions Made)
- Use **bold text** for emphasis on important information
- Use *italic text* for secondary emphasis or highlights
- Use • bullet points for lists and key takeaways
- Use > blockquotes for important statements or direct quotes
- Use --- for section dividers if needed
- Ensure proper spacing between sections

STRUCTURE YOUR SUMMARY WITH THESE SECTIONS (use only relevant sections):
- ## Overview (brief context and main topic)
- ## Key Points (main discussion points and topics)
- ## Decisions Made (any decisions, conclusions, or resolutions)
- ## Action Items (tasks, follow-ups, or next steps mentioned)
- ## Important Details (specific information, dates, names, numbers)
- ## Outcomes (results, agreements, or conclusions reached)

QUALITY STANDARDS:
- Extract the most important information first
- Include specific details when relevant (names, dates, numbers)
- Maintain the original meaning and context
- Avoid unnecessary repetition
- Use active voice when possible
- Be specific rather than vague

</INSTRUCTIONS>

<TRANSCRIPT>
Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.
</TRANSCRIPT>

<OUTPUT>
Please provide your well-formatted summary at the selected detail level below:
"""#

    static let robustComplete = #"""
You MUST return ONLY valid JSON in the EXACT format specified below. Do not include any other text, explanations, or additional fields.

REQUIRED JSON SCHEMA - You must use these exact field names and structure:
{
  "summary": "string with markdown formatting",
  "tasks": [array of task objects],
  "reminders": [array of reminder objects],
  "titles": [array of title objects],
  "contentType": "string value"
}

CRITICAL INSTRUCTIONS:
1. Use ONLY the field names: summary, tasks, reminders, titles, contentType
2. Do NOT use fields like: transcript, key_points, participants, topics_discussed, next_steps
3. Return ONLY the JSON object, no additional text
4. Ensure all required fields are present (use empty arrays if no content)

TASK OBJECTS FORMAT:
{
  "text": "actionable task description",
  "priority": "High" or "Medium" or "Low",
  "category": "Call" or "Email" or "Meeting" or "Purchase" or "Research" or "Travel" or "Health" or "General",
  "timeReference": "specific time mentioned" or null
}

REMINDER OBJECTS FORMAT:
{
  "text": "reminder description",
  "urgency": "Immediate" or "Today" or "This Week" or "Later",
  "timeReference": "specific time/date mentioned" or null
}

TITLE OBJECTS FORMAT:
{
  "text": "Descriptive Title (40-60 chars)",
  "category": "Meeting" or "Personal" or "Technical" or "General",
  "confidence": 0.85
}

SUMMARY FORMAT:
Create a markdown-formatted summary using:
- ## for headers
- **bold** for emphasis
- • for bullet points
- \n for line breaks in the JSON string
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.

CONTENT TYPE: Choose one: "Meeting", "Personal", "Technical", or "General"


Now analyze this transcript and return the JSON:
Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.
"""#

    static let structuredComplete = #"""
You are analyzing a transcript. Extract and summarize the ACTUAL CONTENT discussed, not a description of what type of document it is.

Return ONLY a valid JSON object (no other text):

{
  "summary": "Comprehensive Markdown summary of the CONTENT and TOPICS discussed",
  "tasks": [{"text": "Specific action item", "priority": "High|Medium|Low", "category": "Call|Email|Meeting|Purchase|Research|Travel|Health|General", "timeReference": null}],
  "reminders": [{"text": "Time-sensitive item", "urgency": "Immediate|Today|This Week|Later", "timeReference": null}],
  "titles": [{"text": "Descriptive title", "category": "Meeting|Personal|Technical|General", "confidence": 0.8}],
  "contentType": "Meeting|Personal|Technical|General"
}

CRITICAL INSTRUCTIONS FOR SUMMARY:
- DO NOT write "This is a transcript of..." or "The text appears to be..."
- DO write what was ACTUALLY DISCUSSED in the content
- Follow the selected summary detail level:
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.
- Include the major topics, key points, important details, names, dates, decisions, and conclusions that fit that level
- Use Markdown: ## headers for sections, **bold** for key terms, • bullets for lists
- Structure the summary logically by topic or chronologically

TASKS - Extract ONLY if the speaker mentions THEIR OWN action items:
- "I need to call John" → YES, extract this
- "The government might shut down" → NO, this is not a personal task
- "We should analyze this data" → YES if it's an assignment, NO if it's general commentary
- "Remember to buy groceries" → YES, this is a personal task
- DO NOT create meta-tasks like "summarize the content" or "analyze the transcript"
- DO NOT create questions like "What is the main topic?" - These are NOT tasks
- If NO personal action items are mentioned, return an EMPTY tasks array []

REMINDERS - Extract ONLY personal time-sensitive items:
- "Meeting tomorrow at 3pm" → YES
- "Election day is coming" → NO (not personal)
- "Doctor appointment next Tuesday" → YES
- DO NOT include facts or statements like "The main topic is..." - These are NOT reminders
- If NO personal time-sensitive items are mentioned, return an EMPTY reminders array []

TITLES - Create 3-5 titles about what was DISCUSSED, not what the document is:
- GOOD: "Government Shutdown Impacts Federal Employees"
- BAD: "News Program Transcript"
- GOOD: "Q4 Sales Strategy and Marketing Budget"
- BAD: "Meeting Recording"

CONTENT TYPE:
- Meeting: Work meetings, discussions, collaborations
- Personal: Personal conversations, journals, notes
- Technical: Lectures, tutorials, technical content
- General: News, media, general information



Now analyze this transcript and extract the CONTENT (not meta-commentary about what it is):

Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.
"""#

    static let summaryTool = #"""
{
  "function" : {
    "description" : "Create a comprehensive summary of the transcript with proper Markdown formatting",
    "name" : "create_summary",
    "parameters" : {
      "properties" : {
        "summary" : {
          "description" : "Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical. Use Markdown headers, bold text, and bullets where useful.",
          "type" : "string"
        }
      },
      "required" : [
        "summary"
      ],
      "type" : "object"
    }
  },
  "type" : "function"
}
"""#

    static let completeTool = #"""
{
  "function" : {
    "description" : "Perform complete analysis extracting summary, tasks, reminders, titles, and content type",
    "name" : "complete_analysis",
    "parameters" : {
      "properties" : {
        "contentType" : {
          "description" : "Content classification: Meeting, Personal, Technical, or General",
          "type" : "string"
        },
        "reminders" : {
          "description" : "Array of time-sensitive reminders",
          "items" : {
            "description" : "Reminder object",
            "properties" : {
              "text" : {
                "description" : "Reminder description",
                "type" : "string"
              },
              "timeReference" : {
                "description" : "Specific time\/date mentioned or null",
                "type" : "string"
              },
              "urgency" : {
                "description" : "Urgency: Immediate, Today, This Week, or Later",
                "type" : "string"
              }
            },
            "required" : [
              "text",
              "urgency"
            ],
            "type" : "object"
          },
          "type" : "array"
        },
        "summary" : {
          "description" : "Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical. Use Markdown headers, bold text, and bullets where useful.",
          "type" : "string"
        },
        "tasks" : {
          "description" : "Array of actionable tasks extracted from the content",
          "items" : {
            "description" : "Task object",
            "properties" : {
              "category" : {
                "description" : "Category: Call, Email, Meeting, Purchase, Research, Travel, Health, or General",
                "type" : "string"
              },
              "priority" : {
                "description" : "Priority: High, Medium, or Low",
                "type" : "string"
              },
              "text" : {
                "description" : "Task description",
                "type" : "string"
              },
              "timeReference" : {
                "description" : "Time reference mentioned or null",
                "type" : "string"
              }
            },
            "required" : [
              "text",
              "priority",
              "category"
            ],
            "type" : "object"
          },
          "type" : "array"
        },
        "titles" : {
          "description" : "Array of descriptive titles for the content",
          "items" : {
            "description" : "Title object",
            "properties" : {
              "category" : {
                "description" : "Category: Meeting, Personal, Technical, or General",
                "type" : "string"
              },
              "confidence" : {
                "description" : "Confidence score (0.0-1.0)",
                "type" : "number"
              },
              "text" : {
                "description" : "Descriptive title (40-60 characters)",
                "type" : "string"
              }
            },
            "required" : [
              "text",
              "category",
              "confidence"
            ],
            "type" : "object"
          },
          "type" : "array"
        }
      },
      "required" : [
        "summary",
        "tasks",
        "reminders",
        "titles",
        "contentType"
      ],
      "type" : "object"
    }
  },
  "type" : "function"
}
"""#

    static let schema = #"""
{
  "properties" : {
    "contentType" : {
      "enum" : [
        "Meeting",
        "Personal",
        "Technical",
        "General"
      ],
      "type" : "string"
    },
    "reminders" : {
      "description" : "Array of time-sensitive items with specific deadlines or times",
      "items" : {
        "properties" : {
          "text" : {
            "description" : "Reminder description with specific time reference",
            "type" : "string"
          },
          "timeReference" : {
            "description" : "Specific time\/date mentioned or null",
            "type" : [
              "string",
              "null"
            ]
          },
          "urgency" : {
            "enum" : [
              "Immediate",
              "Today",
              "This Week",
              "Later"
            ],
            "type" : "string"
          }
        },
        "required" : [
          "text",
          "urgency"
        ],
        "type" : "object"
      },
      "type" : "array"
    },
    "summary" : {
      "description" : "Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical.",
      "minLength" : 100,
      "type" : "string"
    },
    "tasks" : {
      "description" : "Array of unique, specific action items. Each task must be different from the others.",
      "items" : {
        "properties" : {
          "category" : {
            "enum" : [
              "Call",
              "Email",
              "Meeting",
              "Purchase",
              "Research",
              "Travel",
              "Health",
              "General"
            ],
            "type" : "string"
          },
          "priority" : {
            "enum" : [
              "High",
              "Medium",
              "Low"
            ],
            "type" : "string"
          },
          "text" : {
            "description" : "Concise, specific, UNIQUE task description (one clear action item, not a long explanation). Must be different from other tasks.",
            "type" : "string"
          },
          "timeReference" : {
            "description" : "Time reference mentioned or null",
            "type" : [
              "string",
              "null"
            ]
          }
        },
        "required" : [
          "text",
          "priority",
          "category"
        ],
        "type" : "object"
      },
      "type" : "array"
    },
    "titles" : {
      "description" : "Array of 3-5 diverse, descriptive titles. Each title should capture a different aspect or topic. REQUIRED field - must generate at least 3 titles.",
      "items" : {
        "properties" : {
          "category" : {
            "enum" : [
              "Meeting",
              "Personal",
              "Technical",
              "General"
            ],
            "type" : "string"
          },
          "confidence" : {
            "maximum" : 1,
            "minimum" : 0.5,
            "type" : "number"
          },
          "text" : {
            "description" : "Descriptive, unique title (40-60 characters). Each title must be different and capture a distinct aspect of the content.",
            "maxLength" : 80,
            "minLength" : 10,
            "type" : "string"
          }
        },
        "required" : [
          "text",
          "category",
          "confidence"
        ],
        "type" : "object"
      },
      "maxItems" : 5,
      "minItems" : 3,
      "type" : "array"
    }
  },
  "required" : [
    "summary",
    "tasks",
    "reminders",
    "titles",
    "contentType"
  ],
  "type" : "object"
}
"""#

    static let qwenSummary = #"""
<|im_start|>system
You are a helpful assistant. You have access to the following functions and MUST use them to respond.

<tools>
[
  {
    "type": "function",
    "function": {
      "name": "create_summary",
      "description": "Create a comprehensive summary of the transcript with proper Markdown formatting",
      "parameters": {
        "type": "object",
        "properties": {
          "summary": {
            "type": "string",
            "description": "Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical. Use ## headers, **bold** text, • bullet points, and proper structure"
          }
        },
        "required": ["summary"]
      }
    }
  }
]
</tools>

SUMMARY DETAIL REQUIREMENT:
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.



IMPORTANT: You MUST respond by calling the create_summary function using this exact format:
<tool_call>
{"name": "create_summary", "arguments": {"summary": "your markdown summary here"}}
</tool_call>

Do not provide a direct response. Use the tool call format.<|im_end|>
<|im_start|>user
Please summarize this transcript:

Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.<|im_end|>
<|im_start|>assistant
"""#

    static let gptossSummary = #"""
You have access to custom analysis tools via the commentary channel.

Available function: create_summary
Description: Create a comprehensive summary of the transcript with proper Markdown formatting
Parameters:
- summary (string): Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical. Use ## headers, **bold** text, • bullet points, and proper structure

SUMMARY DETAIL REQUIREMENT:
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.



Please analyze the following transcript and use the create_summary function to generate a well-structured summary:

Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.

Use the commentary channel to call the create_summary function with the appropriate parameters.
"""#

    static let magistralSummary = #"""
[SYSTEM_PROMPT]
You are a helpful assistant that can use tools to analyze content.

[AVAILABLE_TOOLS]
[
  {
    "name": "create_summary",
    "description": "Create a comprehensive summary of the transcript with proper Markdown formatting",
    "parameters": {
      "type": "object",
      "properties": {
        "summary": {
          "type": "string",
          "description": "Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical. Use ## headers, **bold** text, • bullet points, and proper structure"
        }
      },
      "required": ["summary"]
    }
  }
]

SUMMARY DETAIL REQUIREMENT:
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.



[INST]Please analyze the following transcript and use the create_summary tool to generate a well-structured summary:

Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.[/INST]

<think>
I need to analyze this transcript and create a comprehensive summary using the create_summary tool. Let me process the content and structure it properly.
</think>

"""#

    static let qwenComplete = #"""
<|im_start|>system
You are a helpful assistant. You have access to the following functions and MUST use them to respond.

<tools>
[
  {
    "type": "function",
    "function": {
      "name": "complete_analysis",
      "description": "Perform complete analysis extracting summary, tasks, reminders, titles, and content type",
      "parameters": {
        "type": "object",
        "properties": {
          "summary": {
            "type": "string",
            "description": "Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical. Use ## headers, **bold** text, and • bullets"
          },
          "tasks": {
            "type": "array",
            "description": "Array of actionable tasks extracted from the content",
            "items": {
              "type": "object",
              "properties": {
                "text": {"type": "string", "description": "Task description"},
                "priority": {"type": "string", "description": "Priority: High, Medium, or Low"},
                "category": {"type": "string", "description": "Category: Call, Email, Meeting, Purchase, Research, Travel, Health, or General"},
                "timeReference": {"type": "string", "description": "Time reference mentioned or null"}
              },
              "required": ["text", "priority", "category"]
            }
          },
          "reminders": {
            "type": "array",
            "description": "Array of time-sensitive reminders",
            "items": {
              "type": "object",
              "properties": {
                "text": {"type": "string", "description": "Reminder description"},
                "urgency": {"type": "string", "description": "Urgency: Immediate, Today, This Week, or Later"},
                "timeReference": {"type": "string", "description": "Specific time/date mentioned or null"}
              },
              "required": ["text", "urgency"]
            }
          },
          "titles": {
            "type": "array",
            "description": "Array of descriptive titles for the content",
            "items": {
              "type": "object",
              "properties": {
                "text": {"type": "string", "description": "Descriptive title (40-60 characters)"},
                "category": {"type": "string", "description": "Category: Meeting, Personal, Technical, or General"},
                "confidence": {"type": "number", "description": "Confidence score (0.0-1.0)"}
              },
              "required": ["text", "category", "confidence"]
            }
          },
          "contentType": {
            "type": "string",
            "description": "Content classification: Meeting, Personal, Technical, or General"
          }
        },
        "required": ["summary", "tasks", "reminders", "titles", "contentType"]
      }
    }
  }
]
</tools>

SUMMARY DETAIL REQUIREMENT:
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.



IMPORTANT: You MUST respond by calling the complete_analysis function using this exact format:
<tool_call>
{"name": "complete_analysis", "arguments": {"summary": "...", "tasks": [...], "reminders": [...], "titles": [...], "contentType": "..."}}
</tool_call>

Do not provide a direct response. Use the tool call format.<|im_end|>
<|im_start|>user
Please analyze this transcript comprehensively:

Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.<|im_end|>
<|im_start|>assistant
"""#

    static let gptossComplete = #"""
You have access to custom analysis tools via the commentary channel.

Available function: complete_analysis
Description: Perform complete analysis extracting summary, tasks, reminders, titles, and content type
Parameters:
- summary (string): Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical. Use ## headers, **bold** text, and • bullets

SUMMARY DETAIL REQUIREMENT:
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.
- tasks (array): Array of task objects with text, priority (High/Medium/Low), category (Call/Email/Meeting/Purchase/Research/Travel/Health/General), timeReference
- reminders (array): Array of reminder objects with text, urgency (Immediate/Today/This Week/Later), timeReference
- titles (array): Array of title objects with text (40-60 chars), category (Meeting/Personal/Technical/General), confidence (0.0-1.0)
- contentType (string): Classification as Meeting/Personal/Technical/General



Please analyze the following transcript and use the complete_analysis function to provide comprehensive analysis:

Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.

Use the commentary channel to call the complete_analysis function with all required parameters.
"""#

    static let magistralComplete = #"""
[SYSTEM_PROMPT]
You are a helpful assistant that can use tools to perform comprehensive content analysis.

[AVAILABLE_TOOLS]
[
  {
    "name": "complete_analysis",
    "description": "Perform complete analysis extracting summary, tasks, reminders, titles, and content type",
    "parameters": {
      "type": "object",
      "properties": {
        "summary": {
          "type": "string",
          "description": "Balanced summary: A practical mix of the main ideas and supporting context. Target approximately 10–15% of the source when practical. Use ## headers, **bold** text, and • bullets"
        },
        "tasks": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": {"type": "string", "description": "Task description"},
              "priority": {"type": "string", "description": "Priority: High, Medium, or Low"},
              "category": {"type": "string", "description": "Category: Call, Email, Meeting, Purchase, Research, Travel, Health, or General"},
              "timeReference": {"type": "string", "description": "Time reference mentioned or null"}
            }
          }
        },
        "reminders": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": {"type": "string", "description": "Reminder description"},
              "urgency": {"type": "string", "description": "Urgency: Immediate, Today, This Week, or Later"},
              "timeReference": {"type": "string", "description": "Specific time/date mentioned or null"}
            }
          }
        },
        "titles": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": {"type": "string", "description": "Descriptive title (40-60 characters)"},
              "category": {"type": "string", "description": "Category: Meeting, Personal, Technical, or General"},
              "confidence": {"type": "number", "description": "Confidence score (0.0-1.0)"}
            }
          }
        },
        "contentType": {
          "type": "string",
          "description": "Content classification: Meeting, Personal, Technical, or General"
        }
      },
      "required": ["summary", "tasks", "reminders", "titles", "contentType"]
    }
  }
]

SUMMARY DETAIL REQUIREMENT:
**Summary Detail: Balanced (10–15% of the source when practical)**
- Target approximately 40-60 words for the narrative summary when the transcript is long enough.
- Include the main ideas plus the context, facts, dates, decisions, and conclusions needed to understand them.
- Use clear Markdown sections and bullets where they improve readability.
- Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
- Apply this length preference only to the narrative `summary` field or Summary section.
- Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.



[INST]Please analyze the following transcript and use the complete_analysis tool to provide comprehensive analysis:

Alice said the budget review moves to Friday. Bob will email the vendor about the contract renewal before Thursday.[/INST]

<think>
I need to perform a complete analysis of this transcript, extracting summary, tasks, reminders, titles, and content type. Let me use the complete_analysis tool with all required parameters.
</think>

"""#

}
