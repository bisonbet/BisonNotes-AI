//
//  AccessibilityIdentifiers.swift
//  BisonNotes AI
//

import Foundation

enum BisonNotesAccessibilityID {
    static let appReady = "bisonnotes.app.ready"

    static let tabRecord = "bisonnotes.tab.record"
    static let tabTranscripts = "bisonnotes.tab.transcripts"
    static let tabSummaries = "bisonnotes.tab.summaries"
    static let tabSetup = "bisonnotes.tab.setup"

    static let startRecordingButton = "bisonnotes.record.start"
    static let recordingTimer = "bisonnotes.record.timer"
    static let pauseRecordingButton = "bisonnotes.record.pause"
    static let resumeRecordingButton = "bisonnotes.record.resume"
    static let stopRecordingButton = "bisonnotes.record.stop"
    static let liveTranscript = "bisonnotes.record.live-transcript"
    static let importAudioButton = "bisonnotes.record.import-audio"
    static let importLinkButton = "bisonnotes.record.import-link"
    static let importTranscriptButton = "bisonnotes.record.import-transcript"
    static let viewRecordingsButton = "bisonnotes.record.view-recordings"
    static let recordingsList = "bisonnotes.recordings.list"
    static let recordingRowPrefix = "bisonnotes.recording.row."
    static let generateTranscriptPrefix = "bisonnotes.recording.generate-transcript."
    static let keepOnThisDevicePrefix = "bisonnotes.recording.keep-on-this-device."

    static let setupScroll = "bisonnotes.setup.scroll"
    static let setupProcessingMethod = "bisonnotes.setup.processing-method"
    static let setupSaveButton = "bisonnotes.setup.save"
    static let setupAdditionalSettingsButton = "bisonnotes.setup.additional-settings"
    static let settingsScroll = "bisonnotes.settings.scroll"
    static let settingsConfigurationSection = "bisonnotes.settings.configuration.section"
    static let settingsRecordingSection = "bisonnotes.settings.recording.section"
    static let iCloudSection = "bisonnotes.settings.icloud.section"
    static let iCloudEnableToggle = "bisonnotes.settings.icloud.enable"
    static let iCloudReviewItemsButton = "bisonnotes.settings.icloud.review-items"
    static let settingsBehaviorSection = "bisonnotes.settings.behavior.section"
    static let settingsMaintenanceSection = "bisonnotes.settings.maintenance.section"

    static let audioPlayerPlaybackSection = "bisonnotes.audio-player.playback"
    static let audioScrubber = "bisonnotes.audio-player.scrubber"
    static let audioPlayPauseButton = "bisonnotes.audio-player.play-pause"
    static let audioSkipBackwardButton = "bisonnotes.audio-player.skip-backward"
    static let audioSkipForwardButton = "bisonnotes.audio-player.skip-forward"
    static let audioPlayerKeepOnThisDevice = "bisonnotes.audio-player.keep-on-this-device"

    static let transcriptList = "bisonnotes.transcripts.list"
    static let transcriptRowPrefix = "bisonnotes.transcript.row."
    static let transcriptDetail = "bisonnotes.transcript.detail"

    static let summaryList = "bisonnotes.summaries.list"
    static let summaryRowPrefix = "bisonnotes.summary.row."
    static let summaryDetail = "bisonnotes.summary.detail"
}
