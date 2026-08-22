#if os(macOS)
import SwiftUI
import CoreGraphics

private enum MacSettingsPane: String, CaseIterable, Identifiable {
    case general
    case recording
    case transcription
    case aiSettings
    case storage
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .recording:
            return "Recording"
        case .transcription:
            return "Transcription"
        case .aiSettings:
            return "AI"
        case .storage:
            return "Storage"
        case .advanced:
            return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .recording:
            return "mic"
        case .transcription:
            return "waveform"
        case .aiSettings:
            return "sparkles"
        case .storage:
            return "internaldrive"
        case .advanced:
            return "wrench.and.screwdriver"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .general:
            return BisonNotesAccessibilityID.settingsPaneGeneral
        case .recording:
            return BisonNotesAccessibilityID.settingsPaneRecording
        case .transcription:
            return BisonNotesAccessibilityID.settingsPaneTranscription
        case .aiSettings:
            return BisonNotesAccessibilityID.settingsPaneAI
        case .storage:
            return BisonNotesAccessibilityID.settingsPaneStorage
        case .advanced:
            return BisonNotesAccessibilityID.settingsPaneAdvanced
        }
    }
}

struct MacSettingsRootView: View {
    @AppStorage("bisonnotes.mac.settings.selectedPane")
    private var selectedPaneRawValue = MacSettingsPane.general.rawValue

    var body: some View {
        TabView(selection: $selectedPaneRawValue) {
            PreferencesView()
                .nativeMacPresentationContext(.embedded)
                .accessibilityIdentifier(MacSettingsPane.general.accessibilityIdentifier)
                .tabItem {
                    Label(MacSettingsPane.general.title, systemImage: MacSettingsPane.general.systemImage)
                        .accessibilityIdentifier(MacSettingsPane.general.accessibilityIdentifier)
                }
                .tag(MacSettingsPane.general.rawValue)

            MacRecordingSettingsPane()
                .nativeMacPresentationContext(.embedded)
                .accessibilityIdentifier(MacSettingsPane.recording.accessibilityIdentifier)
                .tabItem {
                    Label(MacSettingsPane.recording.title, systemImage: MacSettingsPane.recording.systemImage)
                        .accessibilityIdentifier(MacSettingsPane.recording.accessibilityIdentifier)
                }
                .tag(MacSettingsPane.recording.rawValue)

            TranscriptionSettingsView()
                .nativeMacPresentationContext(.embedded)
                .accessibilityIdentifier(MacSettingsPane.transcription.accessibilityIdentifier)
                .tabItem {
                    Label(MacSettingsPane.transcription.title, systemImage: MacSettingsPane.transcription.systemImage)
                        .accessibilityIdentifier(MacSettingsPane.transcription.accessibilityIdentifier)
                }
                .tag(MacSettingsPane.transcription.rawValue)

            AISettingsView()
                .nativeMacPresentationContext(.embedded)
                .accessibilityIdentifier(MacSettingsPane.aiSettings.accessibilityIdentifier)
                .tabItem {
                    Label(MacSettingsPane.aiSettings.title, systemImage: MacSettingsPane.aiSettings.systemImage)
                        .accessibilityIdentifier(MacSettingsPane.aiSettings.accessibilityIdentifier)
                }
                .tag(MacSettingsPane.aiSettings.rawValue)

            MacStorageSettingsPane()
                .nativeMacPresentationContext(.embedded)
                .accessibilityIdentifier(MacSettingsPane.storage.accessibilityIdentifier)
                .tabItem {
                    Label(MacSettingsPane.storage.title, systemImage: MacSettingsPane.storage.systemImage)
                        .accessibilityIdentifier(MacSettingsPane.storage.accessibilityIdentifier)
                }
                .tag(MacSettingsPane.storage.rawValue)

            MacAdvancedSettingsPane()
                .nativeMacPresentationContext(.embedded)
                .accessibilityIdentifier(MacSettingsPane.advanced.accessibilityIdentifier)
                .tabItem {
                    Label(MacSettingsPane.advanced.title, systemImage: MacSettingsPane.advanced.systemImage)
                        .accessibilityIdentifier(MacSettingsPane.advanced.accessibilityIdentifier)
                }
                .tag(MacSettingsPane.advanced.rawValue)
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 600)
        .onAppear {
            if MacSettingsPane(rawValue: selectedPaneRawValue) == nil {
                selectedPaneRawValue = MacSettingsPane.general.rawValue
            }
        }
    }
}

struct MacSettingsPaneScroll<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundColor(.primary)
                        .accessibilityAddTraits(.isHeader)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(Color(.systemGroupedBackground))
    }
}

struct MacSettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                MacSettingsIcon(systemName: systemImage, tint: tint, size: 30, cornerRadius: 9)

                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct MacSettingsIcon: View {
    let systemName: String
    let tint: Color
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct MacSettingsLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            MacSettingsIcon(systemName: systemImage, tint: tint, size: 38, cornerRadius: 11)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MacSettingsInlineStatus: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .scaleEffect(0.8)
                    .padding(.top, 1)
            } else {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityCard(label: title, value: subtitle)
    }
}
#endif
