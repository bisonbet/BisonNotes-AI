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

/// The Summary Prompt beta's card: the default prompt for new summaries and
/// the way into the prompt list. Choosing and editing are kept apart.
struct SummaryPromptControls: View {
    // Read so the card refreshes when prompts change elsewhere.
    @AppStorage(SummaryPromptLibrary.storageKey) private var libraryJSON = ""
    @AppStorage(SummaryPromptLibrary.defaultPromptIDKey)
    private var defaultPromptID = SummaryPrompt.defaultID
    @State private var showingPromptList = false

    private var prompts: [SummaryPrompt] {
        _ = libraryJSON
        return SummaryPromptLibrary.prompts()
    }

    /// The stored choice, or Default when it names a deleted prompt.
    private var selectedPrompt: SummaryPrompt {
        prompts.first { $0.id == defaultPromptID } ?? .standard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default for new summaries")
                .font(.subheadline.weight(.semibold))

            Picker("Default for new summaries", selection: Binding(
                get: { selectedPrompt.id },
                set: { defaultPromptID = $0 }
            )) {
                ForEach(prompts) { prompt in
                    Text(prompt.name).tag(prompt.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptPicker)

            Text(selectedPrompt.userDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button {
                showingPromptList = true
            } label: {
                HStack {
                    Label("Edit prompts", systemImage: "square.and.pencil")
                    Spacer()
                    Text("\(SummaryPromptLibrary.customCount()) of \(SummaryPromptLibrary.maxCustomPrompts) custom")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptEditButton)

            Text("You can choose a different prompt for any summary when you regenerate it. Tasks, reminders, and titles are not affected.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingPromptList) {
            SummaryPromptsListView()
        }
    }
}

// MARK: - Custom Prompt Notice

/// Shown on settings a custom prompt replaces (Summary Detail, Comedy Mode)
/// while a custom prompt is the default for new summaries. Those controls stay
/// editable so their values survive.
struct CustomSummaryPromptNotice: View {
    @AppStorage(BetaFeatures.masterStorageKey) private var masterEnabled = false
    @AppStorage(BetaFeature.customSummaryPrompt.storageKey) private var featureEnabled = false
    @AppStorage(SummaryPromptLibrary.storageKey) private var libraryJSON = ""
    @AppStorage(SummaryPromptLibrary.defaultPromptIDKey)
    private var defaultPromptID = SummaryPrompt.defaultID

    private var defaultIsCustom: Bool {
        _ = libraryJSON
        return SummaryPromptLibrary.prompt(id: defaultPromptID)?.kind == .custom
    }

    var body: some View {
        if masterEnabled && featureEnabled && defaultIsCustom {
            Label("Not used while a custom prompt is the default for new summaries.", systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Per-Summary Template Picker

/// Chooses the prompt for one summary, such as when regenerating it. Starts
/// from that summary's own prompt; the default for new summaries is untouched.
struct SummaryTemplatePicker: View {
    @Binding var promptID: String
    @AppStorage(SummaryPromptLibrary.storageKey) private var libraryJSON = ""

    private var prompts: [SummaryPrompt] {
        _ = libraryJSON
        return SummaryPromptLibrary.prompts()
    }

    private var selectedPrompt: SummaryPrompt {
        prompts.first { $0.id == promptID } ?? .standard
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
            // until longer names wrapped and overlapped the description.
            Picker("Summary Prompt", selection: Binding(
                get: { selectedPrompt.id },
                set: { promptID = $0 }
            )) {
                ForEach(prompts) { prompt in
                    Text(prompt.name).tag(prompt.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier(BisonNotesAccessibilityID.summaryTemplatePicker)

            Text(selectedPrompt.userDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
