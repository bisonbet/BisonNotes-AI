//
//  SummaryPromptsEditorView.swift
//  BisonNotes AI
//
//  Beta: the list of summary prompts and the editor for one prompt.
//

import SwiftUI

// MARK: - Prompt List

/// Default (locked), Business Meeting and Personal Notes (wording editable),
/// then up to five custom prompts. Tap a row to edit it.
struct SummaryPromptsListView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SummaryPromptLibrary.storageKey) private var libraryJSON = ""
    @State private var path: [String] = []
    @State private var pendingDeletion: SummaryPrompt?

    private var prompts: [SummaryPrompt] {
        _ = libraryJSON
        return SummaryPromptLibrary.prompts()
    }

    private var builtIns: [SummaryPrompt] { prompts.filter { $0.isBuiltIn && $0.isEditable } }
    private var customs: [SummaryPrompt] { prompts.filter { $0.kind == .custom } }

    var body: some View {
        // Its own stack, so the editor can push on both platforms; native
        // macOS Settings does not provide one inside a sheet.
        NavigationStack(path: $path) {
            List {
                Section("Built-in") {
                    HStack {
                        Text("Default")
                        Spacer()
                        Image(systemName: "lock")
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Can't be edited")
                    }

                    ForEach(builtIns) { prompt in
                        NavigationLink(value: prompt.id) {
                            HStack {
                                Text(prompt.name)
                                Spacer()
                                if prompt.isEdited {
                                    Text("Edited")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    ForEach(customs) { prompt in
                        NavigationLink(value: prompt.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prompt.name)
                                if prompt.recordingType != .auto {
                                    Text(prompt.recordingType.displayName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                pendingDeletion = prompt
                            }
                        }
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { customs[$0] }
                        for prompt in doomed {
                            SummaryPromptLibrary.delete(id: prompt.id)
                        }
                    }

                    if customs.count < SummaryPromptLibrary.maxCustomPrompts {
                        Button {
                            path.append(SummaryPromptEditorView.newPromptID)
                        } label: {
                            Label("Add custom prompt", systemImage: "plus")
                        }
                        .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptAddButton)
                    }
                } header: {
                    Text("Custom · \(customs.count) of \(SummaryPromptLibrary.maxCustomPrompts)")
                } footer: {
                    if !customs.isEmpty {
                        #if os(macOS)
                        Text("Right-click a custom prompt to delete it.")
                        #else
                        Text("Swipe a custom prompt to delete it.")
                        #endif
                    }
                }
            }
            .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptList)
            .navigationTitle("Summary Prompts")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { id in
                SummaryPromptEditorView(promptID: id)
            }
            .confirmationDialog(
                "Delete \(pendingDeletion?.name ?? "prompt")?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDeletion {
                        SummaryPromptLibrary.delete(id: pendingDeletion.id)
                    }
                    pendingDeletion = nil
                }
            } message: {
                Text("Summaries made with it keep their text. Regenerating them uses Default.")
            }
        }
        .nativeMacModalSizing(width: 520, height: 560)
    }
}

// MARK: - Prompt Editor

/// Edits one prompt. Built-ins keep their names and can restore their
/// original wording; custom prompts also have a name, a recording type, and
/// Delete.
struct SummaryPromptEditorView: View {
    /// Opens the editor on a new custom prompt that is kept only on Save.
    static let newPromptID = "new-custom-prompt"

    let promptID: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SummaryPrompt?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Group {
            if let draft {
                editor(for: draft)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(isNewPrompt ? "New Prompt" : "Edit Prompt")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let draft {
                        SummaryPromptLibrary.save(draft)
                    }
                    dismiss()
                }
                .disabled(draft == nil)
            }
        }
        .onAppear {
            if draft == nil {
                draft = isNewPrompt
                    ? SummaryPromptLibrary.makeCustomDraft()
                    : SummaryPromptLibrary.prompt(id: promptID)
            }
        }
    }

    private var isNewPrompt: Bool { promptID == Self.newPromptID }

    private var draftBinding: Binding<SummaryPrompt> {
        Binding(
            get: { draft ?? .standard },
            set: { draft = $0 }
        )
    }

    @ViewBuilder
    private func editor(for prompt: SummaryPrompt) -> some View {
        Form {
            Section {
                if prompt.isBuiltIn {
                    Text(prompt.name)
                        .foregroundColor(.secondary)
                } else {
                    TextField("Name", text: Binding(
                        get: { draftBinding.wrappedValue.name },
                        set: { draftBinding.wrappedValue.name = String($0.prefix(SummaryPrompt.maxNameLength)) }
                    ))
                    .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptNameField)
                }
            } header: {
                Text("Name")
            } footer: {
                if prompt.isBuiltIn {
                    Text("Built-in names can't be changed.")
                }
            }

            Section {
                TextEditor(text: Binding(
                    get: { draftBinding.wrappedValue.text },
                    set: { draftBinding.wrappedValue.text = String($0.prefix(SummaryPromptPreset.maxCustomTextLength)) }
                ))
                .frame(minHeight: 160)
                .accessibilityLabel("Prompt")
                .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptTextEditor)
            } header: {
                Text("Prompt")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(prompt.text.count) / \(SummaryPromptPreset.maxCustomTextLength)")
                        .monospacedDigit()
                    Text(footnote(for: prompt))
                }
            }

            if prompt.kind == .custom {
                Section {
                    Picker("Recording type", selection: Binding(
                        get: { draftBinding.wrappedValue.recordingType },
                        set: { draftBinding.wrappedValue.recordingType = $0 }
                    )) {
                        ForEach(SummaryRecordingType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                } footer: {
                    Text("Meeting and Personal Notes replace the automatic content guess, and the summary shows the type as set by you.")
                }

                if !isNewPrompt {
                    Section {
                        Button("Delete Prompt", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else if prompt.text != prompt.original?.text {
                Section {
                    Button("Restore Original") {
                        if let original = prompt.original {
                            draftBinding.wrappedValue.text = original.text
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(BisonNotesAccessibilityID.summaryPromptRestoreButton)
                }
            }
        }
        .confirmationDialog(
            "Delete \(prompt.name)?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                SummaryPromptLibrary.delete(id: prompt.id)
                dismiss()
            }
        } message: {
            Text("Summaries made with it keep their text. Regenerating them uses Default.")
        }
    }

    private func footnote(for prompt: SummaryPrompt) -> String {
        switch prompt.kind {
        case .businessMeeting:
            return "BisonNotes still treats this as a meeting and leaves tasks, reminders, and titles unchanged."
        case .personalNotes:
            return "BisonNotes still treats this as personal notes and leaves tasks, reminders, and titles unchanged."
        case .custom:
            return "Replaces Summary Detail and Comedy Mode. Tasks, reminders, and titles are not affected."
        case .standard:
            return ""
        }
    }
}
