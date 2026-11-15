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

    /// Whether a term is specific enough to scrub. A one-word name such as
    /// "Meeting" would also erase that ordinary word from every log line, so
    /// only multi-word names, file names and long single words qualify.
    static func isRedactable(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, !isIdentifier(trimmed) else { return false }
        return trimmed.contains(" ") || trimmed.contains(".") || trimmed.count >= 12
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

        var result = text
        for term in usable {
            result = result.replacingOccurrences(
                of: term,
                with: placeholder,
                options: [.caseInsensitive]
            )
        }
        return result
    }
}
