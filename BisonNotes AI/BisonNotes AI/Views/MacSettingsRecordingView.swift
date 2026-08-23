#if os(macOS)
import SwiftUI
import AVFoundation
import CoreGraphics

enum MacRecordingPermissionAlert: Identifiable {
    case rationale
    case denied
    case restartRequired

    var id: String {
        switch self {
        case .rationale:
            return "rationale"
        case .denied:
            return "denied"
        case .restartRequired:
            return "restartRequired"
        }
    }
}

struct MacRecordingSettingsPane: View {
    @EnvironmentObject private var recorderVM: AudioRecorderViewModel
    @State private var permissionAlert: MacRecordingPermissionAlert?

    var body: some View {
        MacSettingsPaneScroll(
            title: "Recording",
            subtitle: "Choose the microphone and capture sources used for new recordings."
        ) {
            MacSettingsCard(title: "Microphone", systemImage: "mic", tint: .green) {
                if recorderVM.availableInputs.isEmpty {
                    MacSettingsInlineStatus(
                        title: "No microphones found",
                        subtitle: "Refresh the list or reconnect an input device.",
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                } else {
                    ForEach(recorderVM.availableInputs, id: \.uid) { input in
                        Button {
                            recorderVM.selectedInput = input
                            recorderVM.setPreferredInput()
                        } label: {
                            microphoneInputRow(input)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(input.portName)
                        .accessibilityValue(
                            "\(input.portType.rawValue), "
                                + (recorderVM.selectedInput?.uid == input.uid ? "Selected" : "Not selected")
                        )
                        .accessibilityHint("Selects this microphone for new recordings.")
                    }
                }

                Button {
                    Task { await recorderVM.fetchInputs() }
                } label: {
                    Label("Refresh Microphones", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .accessibilityIdentifier(BisonNotesAccessibilityID.settingsRecordingSection)

            MacSettingsCard(title: "Capture Sources", systemImage: "waveform.badge.mic", tint: .purple) {
                Toggle(isOn: Binding(
                    get: { recorderVM.isMacSystemAudioCaptureEnabled },
                    set: { handleSystemAudioCaptureToggle($0) }
                )) {
                    MacSettingsLabel(
                        title: "Record Meeting Audio",
                        subtitle: "Capture audio playing from other Mac apps while recording",
                        systemImage: "macwindow.on.rectangle",
                        tint: .purple
                    )
                }
                .disabled(recorderVM.isRecording)
                .accessibilityValue(AccessibilitySupport.statusValue(isOn: recorderVM.isMacSystemAudioCaptureEnabled))

                if recorderVM.isMacSystemAudioCaptureEnabled {
                    MacSettingsInlineStatus(
                        title: "Meeting audio capture is enabled",
                        subtitle: "If permission changes later, BisonNotes saves microphone audio only.",
                        systemImage: "rectangle.dashed.badge.record",
                        tint: .orange
                    )
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { recorderVM.isLocationTrackingEnabled },
                    set: { recorderVM.toggleLocationTracking($0) }
                )) {
                    MacSettingsLabel(
                        title: "Location Services",
                        subtitle: "Capture location data with recordings",
                        systemImage: "location.fill",
                        tint: .blue
                    )
                }
                .accessibilityValue(AccessibilitySupport.statusValue(isOn: recorderVM.isLocationTrackingEnabled))

                if recorderVM.isLocationTrackingEnabled {
                    MacSettingsInlineStatus(
                        title: locationStatusText,
                        subtitle: nil,
                        systemImage: locationStatusIcon,
                        tint: locationStatusColor
                    )
                }
            }
        }
        .onAppear {
            Task { await recorderVM.fetchInputs() }
        }
        .alert(item: $permissionAlert) { alert in
            switch alert {
            case .rationale:
                Alert(
                    title: Text("Allow Meeting Audio Capture?"),
                    message: Text(
                        "BisonNotes needs macOS Screen Recording permission to capture audio playing from other Mac "
                            + "apps during a recording. BisonNotes records audio only and does not save screen video."
                    ),
                    primaryButton: .default(Text("Continue")) {
                        requestSystemAudioCapturePermissionAndEnable()
                    },
                    secondaryButton: .cancel(Text("Not Now")) {
                        recorderVM.setMacSystemAudioCaptureEnabled(false)
                    }
                )
            case .denied:
                Alert(
                    title: Text("Screen Recording Permission Needed"),
                    message: Text(
                        "macOS did not grant Screen & System Audio Recording, so BisonNotes will keep recording "
                            + "microphone audio only. Enable BisonNotes in System Settings > Privacy & Security > "
                            + "Screen & System Audio Recording, then quit and reopen BisonNotes."
                    ),
                    primaryButton: .default(Text("Open System Settings")) {
                        openScreenCapturePrivacySettings()
                    },
                    secondaryButton: .cancel(Text("OK")) {
                        recorderVM.setMacSystemAudioCaptureEnabled(false)
                    }
                )
            case .restartRequired:
                Alert(
                    title: Text("Restart BisonNotes to Finish"),
                    message: Text(
                        "macOS granted Screen & System Audio Recording permission. Quit BisonNotes completely and "
                            + "reopen it before recording meeting audio."
                    ),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func microphoneInputRow(_ input: AVAudioSessionPortDescription) -> some View {
        let isSelected = recorderVM.selectedInput?.uid == input.uid

        return HStack(spacing: 14) {
            MacSettingsIcon(systemName: "mic.fill", tint: .green, size: 38, cornerRadius: 11)

            VStack(alignment: .leading, spacing: 3) {
                Text(input.portName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(input.portType.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(isSelected ? .green : .secondary)
        }
        .padding(12)
        .background(isSelected ? Color.green.opacity(0.12) : Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func handleSystemAudioCaptureToggle(_ enabled: Bool) {
        guard enabled else {
            recorderVM.setMacSystemAudioCaptureEnabled(false)
            return
        }

        if CGPreflightScreenCaptureAccess() {
            recorderVM.setMacSystemAudioCaptureEnabled(true)
        } else {
            recorderVM.setMacSystemAudioCaptureEnabled(false)
            permissionAlert = .rationale
        }
    }

    private func requestSystemAudioCapturePermissionAndEnable() {
        if CGPreflightScreenCaptureAccess() {
            recorderVM.setMacSystemAudioCaptureEnabled(true)
            return
        }

        let granted = CGRequestScreenCaptureAccess()
        recorderVM.setMacSystemAudioCaptureEnabled(granted)
        permissionAlert = granted ? .restartRequired : .denied
    }

    private func openScreenCapturePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        PlatformApp.open(url)
    }

    private var locationStatusIcon: String {
        switch recorderVM.locationManager.locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return "location.fill"
        case .denied, .restricted:
            return "location.slash"
        case .notDetermined:
            return "location"
        @unknown default:
            return "location"
        }
    }

    private var locationStatusColor: Color {
        switch recorderVM.locationManager.locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return .green
        case .denied, .restricted:
            return .red
        case .notDetermined:
            return .orange
        @unknown default:
            return .gray
        }
    }

    private var locationStatusText: String {
        switch recorderVM.locationManager.locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return "Location access granted"
        case .denied, .restricted:
            return "Location access denied - Enable in Settings"
        case .notDetermined:
            return "Location permission not requested"
        @unknown default:
            return "Unknown location status"
        }
    }
}
#endif
