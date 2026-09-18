//
//  DiagnosticConsentStore.swift
//  BisonNotes AI
//

import Foundation

/// Stores the automatic technical-report preference locally. It is intentionally
/// not part of CloudKit or the user's synced settings.
final class DiagnosticConsentStore: @unchecked Sendable {
    static let shared = DiagnosticConsentStore()

    static let versionKey = "AutomaticDiagnosticConsent.version"
    static let enabledKey = "AutomaticDiagnosticConsent.enabled"
    static let epochKey = "AutomaticDiagnosticConsent.epoch"
    static let enabledAtKey = "AutomaticDiagnosticConsent.enabledAt"
    static let lastUnexpectedTerminationKey = "AutomaticDiagnosticConsent.lastUnexpectedTermination"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        if userDefaults.object(forKey: Self.versionKey) == nil {
            userDefaults.set(1, forKey: Self.versionKey)
            // New installs and upgrades are opt-in. Do not infer consent from
            // any older diagnostic or analytics preference.
            userDefaults.set(false, forKey: Self.enabledKey)
        }
    }

    var isEnabled: Bool {
        snapshot().isEnabled
    }

    func snapshot(now: Date = Date()) -> DiagnosticConsentSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard defaults.bool(forKey: Self.enabledKey),
              let epochString = defaults.string(forKey: Self.epochKey),
              let epoch = UUID(uuidString: epochString),
              let enabledAt = defaults.object(forKey: Self.enabledAtKey) as? Date else {
            return DiagnosticConsentSnapshot(isEnabled: false, epoch: nil, enabledAt: nil)
        }

        // A future-dated preference is not useful for collection and could make
        // a clock adjustment accidentally classify old reports as post-consent.
        guard enabledAt <= now else {
            return DiagnosticConsentSnapshot(isEnabled: false, epoch: nil, enabledAt: nil)
        }
        return DiagnosticConsentSnapshot(isEnabled: true, epoch: epoch, enabledAt: enabledAt)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, now: Date = Date()) -> DiagnosticConsentSnapshot {
        lock.lock()
        defer { lock.unlock() }

        if enabled {
            let epoch = UUID()
            defaults.set(1, forKey: Self.versionKey)
            defaults.set(true, forKey: Self.enabledKey)
            defaults.set(epoch.uuidString, forKey: Self.epochKey)
            defaults.set(now, forKey: Self.enabledAtKey)
            return DiagnosticConsentSnapshot(isEnabled: true, epoch: epoch, enabledAt: now)
        }

        defaults.set(false, forKey: Self.enabledKey)
        defaults.removeObject(forKey: Self.epochKey)
        defaults.removeObject(forKey: Self.enabledAtKey)
        defaults.removeObject(forKey: Self.lastUnexpectedTerminationKey)
        return DiagnosticConsentSnapshot(isEnabled: false, epoch: nil, enabledAt: nil)
    }

    func recordUnexpectedTerminationIfEligible(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let last = defaults.object(forKey: Self.lastUnexpectedTerminationKey) as? Date,
           now.timeIntervalSince(last) < 24 * 60 * 60 {
            return false
        }
        defaults.set(now, forKey: Self.lastUnexpectedTerminationKey)
        return true
    }
}
