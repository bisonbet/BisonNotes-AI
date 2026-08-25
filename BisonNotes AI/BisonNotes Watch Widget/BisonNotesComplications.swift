import WidgetKit
import SwiftUI

struct BisonNotesEntry: TimelineEntry {
    let date: Date
    let recordingMinutes: Int
    let newNotesCount: Int
    let statusText: String
}

struct BisonNotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> BisonNotesEntry {
        BisonNotesEntry(date: .now, recordingMinutes: 12, newNotesCount: 2, statusText: "Ready")
    }

    func getSnapshot(in context: Context, completion: @escaping (BisonNotesEntry) -> Void) {
        completion(BisonNotesEntry(date: .now, recordingMinutes: 12, newNotesCount: 2, statusText: "Ready"))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BisonNotesEntry>) -> Void) {
        // Replace this with your shared App Group / UserDefaults / file-backed data.
        let entry = BisonNotesEntry(date: .now, recordingMinutes: 12, newNotesCount: 2, statusText: "Ready")
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct BisonNotesComplicationView: View {
    var entry: BisonNotesProvider.Entry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    // Both assets share the same artwork and framing, so the mark keeps its size
    // and position when a face switches between full-color and tinted rendering.
    private var glyphImage: some View {
        Group {
            if renderingMode == .fullColor {
                Image("BisonGlyphColor")
                    .resizable()
            } else {
                Image("BisonGlyphTemplate")
                    .resizable()
            }
        }
        .scaledToFit()
        .widgetAccentable()
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("Rec \(entry.recordingMinutes)m")

        case .accessoryCircular:
            // The artwork carries its own margin, so only a hair of padding is
            // needed to stay clear of the circular mask.
            glyphImage
                .padding(2)
                .widgetLabel {
                    Text("\(entry.newNotesCount) new")
                }

        case .accessoryRectangular:
            HStack(spacing: 5) {
                glyphImage
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(entry.newNotesCount) New Notes")
                        .font(.headline)
                        .widgetAccentable()
                    Text(entry.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .accessoryCorner:
            glyphImage
                .padding(2)
                .widgetLabel {
                    Text("\(entry.newNotesCount)")
                }

        default:
            Text("BN")
        }
    }
}

struct BisonNotesComplication: Widget {
    let kind: String = "BisonNotesComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BisonNotesProvider()) { entry in
            BisonNotesComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("BisonNotes")
        .description("Recording and note status on Apple Watch.")
        .supportedFamilies([
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryCorner
        ])
    }
}

// If you already have a WidgetBundle with @main in your project,
// add BisonNotesComplication() to that bundle instead of keeping this one.
@main
struct BisonNotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        BisonNotesComplication()
    }
}
