//
//  BetaFeaturesSettingsView.swift
//  BisonNotes AI
//
//  Settings controls for Beta Features and the Summary Prompt beta.
//

import SwiftUI

// MARK: - Beta Features Page

/// The Beta Features settings page: the master switch, then one card per
/// `BetaFeature` holding its opt-in and, once enabled, its own settings.
struct BetaFeaturesView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BetaFeatures.masterStorageKey) private var masterEnabled = false
    @State private var showingEnableWarning = false

    var body: some View {
        #if os(macOS)
        pageContent
        #else
        PlatformSettingsNavigationStack {
            pageContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            dismiss()
                        }
                        .fontWeight(.medium)
                    }
                }
        }
        #endif
    }

    private var pageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                masterCard
                if masterEnabled {
                    ForEach(BetaFeature.allCases) { feature in
                        BetaFeatureCard(feature: feature)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 36)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier(BisonNotesAccessibilityID.settingsBetaSection)
        .alert("Turn On Beta Features?", isPresented: $showingEnableWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") {
                masterEnabled = true
            }
        } message: {
            Text(
                "Beta features are still in development and might not work as intended. "
                    + "They may change or be removed in a future update. "
                    + "You can turn them off here at any time."
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Beta Features")
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primary)
                .accessibilityAddTraits(.isHeader)

            Text("Try early features before they are finished.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var masterCard: some View {
        BetaSettingsCard(title: "Beta Features", systemImage: "flask") {
            Toggle("Enable Beta Features", isOn: Binding(
                get: { masterEnabled },
                set: { newValue in
                    // Turning on asks first; turning off is immediate.
                    if newValue && !masterEnabled {
                        showingEnableWarning = true
                    } else {
                        masterEnabled = newValue
                    }
                }
            ))
            .accessibilityValue(AccessibilitySupport.statusValue(isOn: masterEnabled))
            .accessibilityIdentifier(BisonNotesAccessibilityID.settingsBetaMasterToggle)

            Text(
                masterEnabled
                    ? "Turn on the features you want to try below. Turning Beta Features off restores "
                        + "default behavior and keeps your choices for later."
                    : "Early features that may change or be removed. Turning this off restores "
                        + "default behavior and keeps your choices for later."
            )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One beta feature: its opt-in, then its settings while it is on.
private struct BetaFeatureCard: View {
    let feature: BetaFeature
    @AppStorage private var isEnabled: Bool

    init(feature: BetaFeature) {
        self.feature = feature
        _isEnabled = AppStorage(wrappedValue: false, feature.storageKey)
    }

    var body: some View {
        BetaSettingsCard(title: feature.title, systemImage: feature.systemImage, showsBadge: true) {
            Toggle("Enable \(feature.title)", isOn: $isEnabled)
                .accessibilityValue(AccessibilitySupport.statusValue(isOn: isEnabled))
                .accessibilityIdentifier(BisonNotesAccessibilityID.settingsBetaFeatureToggle(feature))

            Text(feature.summary)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isEnabled {
                Divider()
                settings
            }
        }
    }

    @ViewBuilder
    private var settings: some View {
        switch feature {
        case .customSummaryPrompt:
            SummaryPromptControls()
                .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptSection)
        case .transcriptCleanup:
            TranscriptCleanupControls()
        }
    }
}

private struct BetaSettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    var showsBadge = false
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, showsBadge: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.showsBadge = showsBadge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.orange)
                    .frame(width: 30, height: 30)
                    .background(Color.orange.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                if showsBadge {
                    BetaBadge()
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Summary Prompt Controls

/// Picker over the summary prompt presets, with an editor for Custom. Shown on
/// the Beta Features page once the Summary Prompt beta is on.
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
            Text("The default prompt for new AI summaries. You can choose a different one for any summary when you regenerate it. Tasks, reminders, and titles are not affected.")
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

// MARK: - Per-Summary Template Picker

/// Chooses the template for one summary, such as when regenerating it. Starts
/// from that summary's own template; the global setting is untouched.
struct SummaryTemplatePicker: View {
    @Binding var template: SummaryPromptTemplate

    private var presetBinding: Binding<SummaryPromptPreset> {
        Binding(
            get: { template.preset },
            set: { newPreset in
                let customText = newPreset == .custom
                    ? (template.customText ?? SummaryPromptPreset.configuredCustomText())
                    : nil
                template = SummaryPromptTemplate(preset: newPreset, customText: customText)
            }
        )
    }

    private var customTextBinding: Binding<String> {
        Binding(
            get: { template.customText ?? SummaryPromptPreset.defaultCustomText },
            set: { newText in
                // Normalized when the summary is generated; keep what the user
                // is typing, including trailing spaces, while editing.
                template = SummaryPromptTemplate(
                    preset: .custom,
                    customText: String(newText.prefix(SummaryPromptPreset.maxCustomTextLength))
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Summary Prompt")
                    .font(.subheadline.weight(.semibold))
                BetaBadge()
                Spacer(minLength: 0)
            }

            // On its own line: sharing a row with the title squeezed the menu
            // until longer names like "Business Meeting" wrapped and overlapped.
            Picker("Summary Prompt", selection: presetBinding) {
                ForEach(SummaryPromptPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier(BisonNotesAccessibilityID.summaryTemplatePicker)

            Text(template.preset.userDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if template.preset == .custom {
                TextEditor(text: customTextBinding)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Custom summary prompt for this summary")
            }
        }
    }
}
