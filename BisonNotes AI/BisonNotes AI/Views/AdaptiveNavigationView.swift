//
//  AdaptiveNavigationView.swift
//  BisonNotes AI
//
//  Sidebar-based navigation for iPad and Mac Catalyst.
//  On iPhone, ContentView continues to use the existing TabView.
//

import SwiftUI

// MARK: - Environment Key for Embedded Navigation

/// When true, views should skip their own NavigationView wrapper
/// (because they're already inside NavigationSplitView's detail column).
private struct IsEmbeddedInSplitViewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isEmbeddedInSplitView: Bool {
        get { self[IsEmbeddedInSplitViewKey.self] }
        set { self[IsEmbeddedInSplitViewKey.self] = newValue }
    }
}

// MARK: - Adaptive Navigation Wrapper

/// A view modifier that wraps content in NavigationStack only when NOT embedded in a split view.
/// Use this in views like SummariesView and TranscriptsView that have their own NavigationView wrapper.
struct AdaptiveNavigationWrapper<Content: View>: View {
    @Environment(\.isEmbeddedInSplitView) private var isEmbeddedInSplitView
    @ViewBuilder let content: Content

    var body: some View {
        if isEmbeddedInSplitView {
            content
        } else {
            NavigationStack {
                content
            }
        }
    }
}

// MARK: - Sidebar Navigation

enum SidebarItem: String, CaseIterable, Identifiable {
    case record = "Record"
    case summaries = "Summaries"
    case transcripts = "Transcripts"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .record: return "mic.fill"
        case .summaries: return "doc.text.magnifyingglass"
        case .transcripts: return "text.bubble.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct AdaptiveNavigationView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var selectedItem: SidebarItem? = .record

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedItem) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }
            .navigationTitle("BisonNotes AI")
        } detail: {
            Group {
                switch selectedItem {
                case .record:
                    RecordingsView()
                case .summaries:
                    SummariesView()
                case .transcripts:
                    TranscriptsView()
                case .settings:
                    SimpleSettingsView()
                case nil:
                    ContentUnavailableView(
                        "Select a Section",
                        systemImage: "sidebar.left",
                        description: Text("Choose a section from the sidebar to get started.")
                    )
                }
            }
            .environment(\.isEmbeddedInSplitView, true)
            .environmentObject(recorderVM)
            .environmentObject(appCoordinator)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToSection"))) { notification in
            if let section = notification.object as? String {
                switch section {
                case "record": selectedItem = .record
                case "summaries": selectedItem = .summaries
                case "transcripts": selectedItem = .transcripts
                case "settings": selectedItem = .settings
                default: break
                }
            }
        }
    }
}
