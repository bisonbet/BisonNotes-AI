//
//  ActiveAudioWorkRegistry.swift
//  BisonNotes AI
//
//  Audio a feature is actively writing into Documents but has not referenced
//  from Core Data yet.
//
//  A file is only ever a cleanup candidate because no recording row points at
//  it, so any writer that creates the file first and saves the row second is
//  invisible to that test for the whole gap between the two. Recording,
//  importing, restoring, and background jobs each publish their state through a
//  manager the troubleshooting screen can already observe; combining two
//  recordings writes `combined_*.m4a` straight into Documents from view-local
//  state that nothing else can see.
//
//  Registering the path here closes that window without coupling the writer to
//  the troubleshooting screen, and gives any future direct writer one place to
//  declare itself.
//

import Foundation

/// Thread-safe and free of actor isolation on purpose: writers register from
/// whatever context they already run in, and the reviewed-audio guards read it
/// synchronously while deciding whether a file may be removed. Deliberately not
/// `ObservableObject` — nothing renders from it, so no publisher is needed.
final class ActiveAudioWorkRegistry: @unchecked Sendable {
    static let shared = ActiveAudioWorkRegistry()

    private let lock = NSLock()
    private var paths: Set<String> = []

    private init() {}

    /// Claims `url` until the matching `finishWriting`. Safe to call for a file
    /// that does not exist yet: the claim is on the path, not on the bytes.
    func beginWriting(_ url: URL) {
        let path = AdvancedTroubleshootingService.canonicalPath(for: url)
        lock.lock()
        defer { lock.unlock() }
        paths.insert(path)
    }

    func finishWriting(_ url: URL) {
        let path = AdvancedTroubleshootingService.canonicalPath(for: url)
        lock.lock()
        defer { lock.unlock() }
        paths.remove(path)
    }

    /// Canonical paths currently claimed. Empty is the common case.
    var inFlightPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}
