//
//  LogPrivacy.swift
//  BisonNotes AI
//
//  The diagnostic export is a file the user emails to support or anyone else.
//  Recording names and AI-generated titles describe what was recorded — one
//  user's export named a medication change — so they must not ride along.
//
//  Two layers:
//  - Log sites should not interpolate user content in the first place; log an
//    id or a length instead (`LogPrivacy.describe`).
//  - `LogExporter` scrubs every known recording name, summary title and
//    recording file name out of the export as a backstop, because there are
//    many log sites and a new one is easy to add.
//

import Foundation

enum LogPrivacy {
    static let placeholder = "[redacted]"

    /// A loggable stand-in for user content: its length, never its text.
    static func describe(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "<empty>" }
        return "<\(text.count) chars>"
    }

    /// Keeps UUID-based file references useful without disclosing a user filename.
    static func fileReference(_ fileName: String) -> String {
        isIdentifier(fileName) ? fileName : describe(fileName)
    }

    /// File-system error descriptions and userInfo can contain private paths.
    static func errorDescription(_ error: Error) -> String {
        let error = error as NSError
        return "domain=\(error.domain), code=\(error.code)"
    }

    /// Even a short, single-word name can be sensitive. Whole-word matching
    /// below prevents it from erasing substrings of unrelated diagnostic fields.
    static func isRedactable(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isIdentifier(trimmed)
    }

    /// Whether a term is an id rather than something a person wrote: a UUID,
    /// or a file named after one. Audio files are often named by their
    /// recording's id, and scrubbing that removed the id from every log line
    /// that names the recording — the one thing a log is meant to keep.
    static func isIdentifier(_ term: String) -> Bool {
        UUID(uuidString: term) != nil
            || UUID(uuidString: (term as NSString).deletingPathExtension) != nil
    }

    /// Replaces every redactable term in `text` with the placeholder,
    /// case-insensitively. Longer terms go first, so a name is not left half
    /// replaced by a shorter one inside it.
    static func redacting(_ terms: [String], in text: String) -> String {
        let usable = Set(
            terms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter(isRedactable)
        )
        .sorted { $0.count > $1.count }

        // Older breadcrumbs may name a recording that was renamed or deleted,
        // or contain coordinates. Database terms alone cannot protect those.
        var result = redactingLegacyFields(in: text)
        for term in usable {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: term)
                + "(?![\\p{L}\\p{N}_])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let identifiers else { return placeholder }
            let range = NSRange(result.startIndex..., in: result)
            let protected = identifiers.matches(in: result, range: range).map(\.range)
            var redactions: [NSRange] = []
            for match in expression.matches(in: result, range: range) {
                // A name equal to a UUID segment must not damage that UUID.
                // A name surrounding a UUID still needs its other text removed.
                guard !protected.contains(where: {
                    NSIntersectionRange($0, match.range).length == match.range.length
                }) else { continue }
                let expanded = protected.filter { NSIntersectionRange($0, match.range).length > 0 }
                    .reduce(match.range, NSUnionRange)
                if let previous = redactions.last, NSIntersectionRange(previous, expanded).length > 0 {
                    redactions[redactions.count - 1] = NSUnionRange(previous, expanded)
                } else {
                    redactions.append(expanded)
                }
            }
            for redaction in redactions.reversed() {
                guard let matchRange = Range(redaction, in: result) else { continue }
                result.replaceSubrange(matchRange, with: redactedPayload(String(result[matchRange])))
            }
        }
        return result
    }

    /// These older messages placed unstructured user content after the marker.
    /// Remove that entire suffix, retaining UUIDs for cross-log correlation.
    /// This also works when the store is unavailable and there are no terms.
    private static func redactingLegacyFields(in text: String) -> String {
        guard let fields = legacyFields else { return placeholder }
        var result = text
        let matches = fields.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let payloadRange = Range(match.range(at: 1), in: text),
                  let outputRange = Range(match.range(at: 1), in: result) else { continue }
            let payload = String(text[payloadRange])
            let range = NSRange(payload.startIndex..., in: payload)
            if safeFileFields?.firstMatch(in: payload, range: range) != nil { continue }
            result.replaceSubrange(outputRange, with: " " + redactedPayload(payload))
        }
        return result
    }

    private static func redactedPayload(_ payload: String) -> String {
        guard let identifiers else { return placeholder }
        let ids = identifiers.matches(in: payload, range: NSRange(payload.startIndex..., in: payload))
            .compactMap { Range($0.range, in: payload).map { String(payload[$0]) } }
        return placeholder + (ids.isEmpty ? "" : " ids=" + ids.joined(separator: ","))
    }

    private static let identifiers = try? NSRegularExpression(
        pattern: "(?i)[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
    )

    private static let safeFileFields: NSRegularExpression? = {
        let reference = "(?:[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}(?:\\.[a-zA-Z0-9]+)?"
            + "|<[0-9]+ chars>|<empty>|domain=[a-zA-Z0-9_.-]+, code=-?[0-9]+)"
        return try? NSRegularExpression(
            pattern: "^\\s*" + reference + "(?:\\s*(?:->|\\+)\\s*" + reference + ")*"
                + "(?:: domain=[a-zA-Z0-9_.-]+, code=-?[0-9]+| \\(compression: [0-9]+, size: [0-9]+\\))?\\s*$"
        )
    }()

    private static let legacyFields = try? NSRegularExpression(
        pattern: "(?im)(?:" + [
            "Saving location data - lat:",
            "Archive: failed to create staging dir:",
            "Archive: failed to resolve bookmark:",
            "Audio export: failed to create staging dir:",
            "Could not remove unusable startup artifact:",
            "DOCX extraction error:",
            "Error checking for existing recording:",
            "Error deleting recording:",
            "Error deleting summary:",
            "Error deleting transcript:",
            "Error fetching recording by name:",
            "Error fetching recording:",
            "Error getting file metadata:",
            "Error loading file relationships:",
            "Error saving file relationships:",
            "Error saving preservation changes:",
            "Error scanning documents directory:",
            "Failed to load asset properties:",
            "Failed to remove superseded duplicates:",
            "Failed to rename audio file:",
            "Failed to save Core Data entry:",
            "Failed to save URL migrations:",
            "Failed to save URL update:",
            "Failed to save URL updates:",
            "Failed to save cleanup changes:",
            "Failed to save cleanup:",
            "Failed to save fixes:",
            "Failed to save missing file cleanup:",
            "Failed to save name update:",
            "Failed to save repaired summaries:",
            "Failed to save transcript entry:",
            "Failed to start transcription job:",
            "Fallback transcription also failed:",
            "LiveTranscriptionService: export failed:",
            "Recorder startup failed:",
            "Unexpected DOCX extraction error:",
            "Export failed:",
            "Creating summary for recording:",
            "No valid URL found for recording:",
            "Could not resolve URL for recording:",
            "Recording name:",
            "Updating name from ",
            "Audio file renamed:",
            "Updated Core Data URL to match existing file:",
            "Starting to combine recordings:",
            "Successfully combined recordings to:",
            "Starting audio cleanup for ",
            "Starting DOCX extraction for:",
            "Found ZIP entry:",
            "stopped, saved to ",
            "Starting streaming processing for file:",
            "Could not find recording in Core Data for file:",
            "Starting Mistral transcription for:",
            "WyomingWhisperClient.transcribeAudio called for:",
            "WyomingWhisperClient.transcribeAudioStandard called for:",
            "Starting chunked Wyoming transcription for:",
            "Audio chunk created:",
            "Starting single file transcription for:",
            "Starting REST API transcription for:",
            "Starting transcription for:",
            "Starting Wyoming protocol transcription for:",
            "Detecting language for:",
            "Recorded file detected:",
            "Imported file detected:",
            "Successfully imported:",
            "Successfully extracted audio from video:",
            "Copied cleaned audio to Documents:",
            "Created Core Data entry for imported transcript:",
            "File does not exist, using current date for:",
            "Error getting creation date for ",
            "Cleaning up recording with missing file:",
            "expected filename:",
            "Archive: exported URL did not match a staged recording:",
            "Archive: rejected non-iCloud destination ",
            "Archive: skipped untrackable destination URL ",
            "Audio export: failed to stage ",
            "Archive: failed to stage "
        ].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            + "|(?:Updated URL(?: by name match)? for recording ID|Fixed path for recording ID"
            + "|Updated recording URL for ID) [0-9a-fA-F-]{36}:)"
            + "([^\\r\\n]*(?:\\r?\\n(?!\\[\\d{4}-|"
            + "\\[(?:DEBUG|INFO|NOTICE|ERROR|FAULT|DEFAULT|LIFECYCLE)\\]|[─=]{3,})[^\\r\\n]*)*)"
    )
}
