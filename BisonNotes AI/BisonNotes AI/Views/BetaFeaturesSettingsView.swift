//
//  BetaFeaturesSettingsView.swift
//  BisonNotes AI
//
//  Settings controls for Beta Features and the Summary Prompt beta.
//

import SwiftUI

// MARK: - Beta Features Controls

/// Master switch plus one opt-in per `BetaFeature`. Hosts wrap it in their
/// own card so it matches the surrounding settings screen.
struct BetaFeaturesControls: View {
    @AppStorage(BetaFeatures.masterStorageKey) private var masterEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Beta Features", isOn: $masterEnabled)
                .accessibilityValue(AccessibilitySupport.statusValue(isOn: masterEnabled))
                .accessibilityIdentifier(BisonNotesAccessibilityID.settingsBetaMasterToggle)

            Text("Early features that may change or be removed. Turning this off restores default behavior and keeps your choices for later.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if masterEnabled {
                Divider()
                ForEach(BetaFeature.allCases) { feature in
                    BetaFeatureToggleRow(feature: feature)
                }
            }
        }
    }
}

private struct BetaFeatureToggleRow: View {
    let feature: BetaFeature
    @AppStorage private var isEnabled: Bool

    init(feature: BetaFeature) {
        self.feature = feature
        _isEnabled = AppStorage(wrappedValue: false, feature.storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(feature.title, isOn: $isEnabled)
                .accessibilityValue(AccessibilitySupport.statusValue(isOn: isEnabled))
                .accessibilityIdentifier(BisonNotesAccessibilityID.settingsBetaFeatureToggle(feature))
            Text(feature.summary)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Summary Prompt Controls

/// Picker over the summary prompt presets, with an editor for Custom. Render
/// inside `BetaGated(.customSummaryPrompt)`.
struct SummaryPromptControls: View {
    @AppStorage(SummaryPromptPreset.storageKey)
    private var presetRawValue = SummaryPromptPreset.standard.rawValue
    @AppStorage(SummaryPromptPreset.customTextStorageKey)
    private var customText = SummaryPromptPreset.defaultCustomText

    private var selectedPreset: SummaryPromptPreset {
        SummaryPromptPreset(rawValue: presetRawValue) ?? .standard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how AI summaries are written. Tasks, reminders, and titles are not affected.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Prompt", selection: $presetRawValue) {
                ForEach(SummaryPromptPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset.rawValue)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptPicker)

            Text(selectedPreset.userDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if selectedPreset == .custom {
                customEditor
            }
        }
    }

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(
                get: { customText },
                set: { customText = String($0.prefix(SummaryPromptPreset.maxCustomTextLength)) }
            ))
            .frame(minHeight: 120)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Custom summary prompt")
            .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptCustomText)

            HStack {
                Button("Reset to Default") {
                    customText = SummaryPromptPreset.defaultCustomText
                }
                .buttonStyle(.borderless)
                .disabled(customText == SummaryPromptPreset.defaultCustomText)
                .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptResetButton)

                Spacer()

                Text("\(customText.count)/\(SummaryPromptPreset.maxCustomTextLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Text("Replaces Summary Detail and Comedy Mode. An empty prompt uses \"\(SummaryPromptPreset.defaultCustomText)\"")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Custom Prompt Notice

/// Shown on settings a Custom summary prompt replaces (Summary Detail, Comedy
/// Mode). Those controls stay editable so their values survive.
struct CustomSummaryPromptNotice: View {
    @AppStorage(BetaFeatures.masterStorageKey) private var masterEnabled = false
    @AppStorage(BetaFeature.customSummaryPrompt.storageKey) private var featureEnabled = false
    @AppStorage(SummaryPromptPreset.storageKey)
    private var presetRawValue = SummaryPromptPreset.standard.rawValue

    var body: some View {
        if masterEnabled && featureEnabled && presetRawValue == SummaryPromptPreset.custom.rawValue {
            Label("Not used while a Custom summary prompt is active.", systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
