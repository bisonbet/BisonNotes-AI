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
    @Environment(\.showsWidgetLabel) private var showsWidgetLabel

    private var glyphImage: some View {
        Group {
            if renderingMode == .fullColor {
                Image("BisonGlyphColor")
                    .resizable()
                    .scaledToFit()
            } else {
                Image("BisonGlyphTemplate")
                    .resizable()
                    .scaledToFit()
            }
        }
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("Rec \(entry.recordingMinutes)m")

        case .accessoryCircular:
            glyphImage
                .padding(4)
                .widgetLabel {
                    if showsWidgetLabel {
                        Text("\(entry.newNotesCount) new")
                    }
                }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("BisonNotes")
                    .font(.headline)
                Text("\(entry.newNotesCount) New Notes")
                    .font(.system(size: 16, weight: .semibold))
                Text(entry.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

        case .accessoryCorner:
            glyphImage
                .padding(4)
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
