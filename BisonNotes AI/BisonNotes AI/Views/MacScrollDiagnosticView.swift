//
//  MacScrollDiagnosticView.swift
//  BisonNotes AI
//
//  Temporary diagnostic harness for isolating Mac Catalyst sheet scroll bugs.
//  Each variant presents the SAME 200-row content with a different wrapper so
//  we can pinpoint exactly which wrapping prevents the SwiftUI ScrollView /
//  HostingScrollView from receiving usable bounds.
//
//  Delete this file (and the call site in SettingsView.debugSection) once the
//  scrolling regression is resolved.
//

import SwiftUI

struct MacScrollDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showingBareScrollView = false
    @State private var showingNavStackScrollView = false
    @State private var showingSafeAreaInsetScrollView = false
    @State private var showingVStackScrollView = false
    @State private var showingFormControl = false

    var body: some View {
        Form {
            Section {
                Text("Open each sheet in turn and try to scroll with the trackpad / scroll wheel and by grabbing the scrollbar. Note which ones scroll and which don't.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section("Tests") {
                Button("Test 1: Bare ScrollView (no wrapper)") {
                    showingBareScrollView = true
                }
                Button("Test 2: NavigationStack { ScrollView } + toolbar") {
                    showingNavStackScrollView = true
                }
                Button("Test 3: ScrollView + safeAreaInset header") {
                    showingSafeAreaInsetScrollView = true
                }
                Button("Test 4: VStack { Header; ScrollView }") {
                    showingVStackScrollView = true
                }
            }

            Section("Control") {
                Button("Test 5: NavigationStack { Form } (known-good)") {
                    showingFormControl = true
                }
            }

            Section {
                Button("Close") { dismiss() }
            }
        }
        // Test 1: bare ScrollView. No NavigationStack, no header, no insets.
        // The first row is a Close button so we can always escape, even if scrolling fails.
        .sheet(isPresented: $showingBareScrollView) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Button("Close") { showingBareScrollView = false }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    ForEach(0..<200, id: \.self) { i in
                        Text("Bare row \(i)")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        // Test 2: matches AISettingsView's pattern but with ScrollView instead of Form.
        .sheet(isPresented: $showingNavStackScrollView) {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<200, id: \.self) { i in
                            Text("NavStack row \(i)")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .navigationTitle("NavStack + ScrollView")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { showingNavStackScrollView = false }
                    }
                }
            }
        }
        // Test 3: current pattern in SettingsView/SummaryDetailView/TranscriptDetailView.
        .sheet(isPresented: $showingSafeAreaInsetScrollView) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<200, id: \.self) { i in
                        Text("safeAreaInset row \(i)")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("safeAreaInset header").font(.headline)
                        Spacer()
                        Button("Done") { showingSafeAreaInsetScrollView = false }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                }
                .background(.regularMaterial)
            }
        }
        // Test 4: previous pattern with header above ScrollView in same VStack.
        .sheet(isPresented: $showingVStackScrollView) {
            VStack(spacing: 0) {
                HStack {
                    Text("VStack header").font(.headline)
                    Spacer()
                    Button("Done") { showingVStackScrollView = false }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<200, id: \.self) { i in
                            Text("VStack row \(i)")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        // Test 5: control. AISettingsView uses this exact pattern and works.
        .sheet(isPresented: $showingFormControl) {
            NavigationStack {
                Form {
                    ForEach(0..<200, id: \.self) { i in
                        Text("Form row \(i)")
                    }
                }
                .navigationTitle("Form (control)")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { showingFormControl = false }
                    }
                }
            }
        }
    }
}
