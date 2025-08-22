import WidgetKit
import SwiftUI

struct BisonNotesComplicationEntry: TimelineEntry {
    let date: Date
}

struct BisonNotesComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> BisonNotesComplicationEntry {
        BisonNotesComplicationEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (BisonNotesComplicationEntry) -> Void) {
        let entry = BisonNotesComplicationEntry(date: Date())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BisonNotesComplicationEntry>) -> Void) {
        let entry = BisonNotesComplicationEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct BisonNotesComplicationEntryView: View {
    var entry: BisonNotesComplicationProvider.Entry

    var body: some View {
        Image(systemName: "pencil")
            .widgetURL(URL(string: "bisonnotes://complication"))
    }
}

    private enum Constants {
        static let complicationURL = "bisonnotes://complication"
    }

    var body: some View {
        Image(systemName: "pencil")
            .widgetURL(URL(string: Constants.complicationURL))
    }
    let kind: String = "BisonNotesComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BisonNotesComplicationProvider()) { entry in
            BisonNotesComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("BisonNotes")
        .description("Open BisonNotes quickly from your watch.")
        .supportedFamilies([.accessoryCircular])
    }
}
