//
//  BisonNotesMacWidget.swift
//  BisonNotes Mac Widget
//

import AppIntents
import SwiftUI
import WidgetKit

struct MacRecordingWidgetEntry: TimelineEntry {
    let date: Date
}

struct MacRecordingTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacRecordingWidgetEntry {
        MacRecordingWidgetEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (MacRecordingWidgetEntry) -> Void
    ) {
        completion(MacRecordingWidgetEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<MacRecordingWidgetEntry>) -> Void
    ) {
        completion(Timeline(entries: [MacRecordingWidgetEntry(date: Date())], policy: .never))
    }
}

struct MacRecordingWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var entry: MacRecordingTimelineProvider.Entry

    var body: some View {
        Group {
            if family == .systemMedium {
                mediumLayout
            } else {
                smallLayout
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.19, blue: 0.31),
                    Color(red: 0.02, green: 0.32, blue: 0.42)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            brandMark

            VStack(alignment: .leading, spacing: 2) {
                Text("Capture a note")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Ready when you are.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            recordButton
        }
    }

    private var mediumLayout: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                brandMark

                VStack(alignment: .leading, spacing: 3) {
                    Text("Capture a note")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Ready when you are.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            recordButton
        }
    }

    private var brandMark: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 34, height: 34)

                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("BISONNOTES AI")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    private var recordButton: some View {
        Button(intent: StartRecordingIntent()) {
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .widgetAccentable()

                Capsule()
                    .stroke(.white.opacity(0.72), lineWidth: 1.5)
                    .widgetAccentable(false)

                HStack(spacing: 7) {
                    Image(systemName: "mic.fill")
                    Text("Record")
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .widgetAccentable(false)
            }
            .frame(minWidth: 100, minHeight: 42)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start recording")
        .accessibilityHint("Opens BisonNotes AI and begins a new audio note")
    }
}

struct BisonNotesMacRecordingWidget: Widget {
    static let kind = "com.bisonnotesai.mac.start-recording"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: MacRecordingTimelineProvider()
        ) { entry in
            MacRecordingWidgetView(entry: entry)
        }
        .configurationDisplayName("Start Recording")
        .description("Start a new audio note in BisonNotes AI.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct BisonNotesMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        BisonNotesMacRecordingWidget()
    }
}
