//
//  BetaFeatures.swift
//  BisonNotes AI
//
//  Opt-in gate for features that may change or be removed.
//

import SwiftUI

// MARK: - Beta Feature Catalog

/// A feature that is hidden and inert unless the user turns on Beta Features
/// and then opts in to this feature specifically.
///
/// To gate a new feature: add a case here, give it a title and summary, read
/// `BetaFeatures.isEnabled(_:)` wherever the feature changes behavior, and wrap
/// its settings in `BetaGated`. The per-feature key is added to iCloud settings
/// backup automatically through `BetaFeatures.allStorageKeys`.
enum BetaFeature: String, CaseIterable, Identifiable, Sendable {
    case customSummaryPrompt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .customSummaryPrompt:
            return "Summary Prompt"
        }
    }

    var summary: String {
        switch self {
        case .customSummaryPrompt:
            return "Choose a Personal Notes, Business Meeting, or custom prompt for AI summaries."
        }
    }

    var storageKey: String { "betaFeature.\(rawValue).enabled" }
}

// MARK: - Beta Feature Gate

enum BetaFeatures {
    static let masterStorageKey = "betaFeaturesEnabled"

    /// Every key the gate reads, for iCloud settings backup.
    static var allStorageKeys: [String] {
        [masterStorageKey] + BetaFeature.allCases.map(\.storageKey)
    }

    static func isMasterEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: masterStorageKey)
    }

    /// The only runtime gate. Turning the master switch off never clears a
    /// feature's own flag or settings, so turning it back on restores them.
    static func isEnabled(_ feature: BetaFeature, defaults: UserDefaults = .standard) -> Bool {
        isMasterEnabled(defaults: defaults) && defaults.bool(forKey: feature.storageKey)
    }
}

// MARK: - SwiftUI Gate

/// Renders its content only while Beta Features and the given feature are both on.
struct BetaGated<Content: View>: View {
    private let content: Content

    @AppStorage private var masterEnabled: Bool
    @AppStorage private var featureEnabled: Bool

    init(_ feature: BetaFeature, @ViewBuilder content: () -> Content) {
        self.content = content()
        _masterEnabled = AppStorage(wrappedValue: false, BetaFeatures.masterStorageKey)
        _featureEnabled = AppStorage(wrappedValue: false, feature.storageKey)
    }

    var body: some View {
        if masterEnabled && featureEnabled {
            content
        }
    }
}

/// Small capsule marking a setting as Beta.
struct BetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundColor(.orange)
            .accessibilityLabel("Beta feature")
    }
}
