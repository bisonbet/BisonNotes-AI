//
//  AcknowledgementsView.swift
//  BisonNotes AI
//

import SwiftUI

struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showTransitiveDependencies = false

    var body: some View {
        Group {
            #if os(macOS)
            nativeMacContent
            #else
            Form {
                Section {
                    Text("BisonNotes AI is built on the shoulders of outstanding open-source projects.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section("Direct Dependencies") {
                    ForEach(directDependencies) { dependency in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(dependency.name)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(dependency.license)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(dependency.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Link(dependency.linkText, destination: dependency.url)
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    DisclosureGroup("Transitive Dependencies", isExpanded: $showTransitiveDependencies) {
                        ForEach(transitiveDependencyGroups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                ForEach(group.projects) { project in
                                    Link(project.name, destination: project.url)
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } footer: {
                    Text(
                        "These are brought in through the app's direct and transitive software dependencies. "
                            + "The software dependencies are MIT or Apache 2.0 licensed as shown; see each "
                            + "repository for terms."
                    )
                }

                Section("Downloaded Model Assets") {
                    modelAssetLinks
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        .platformSettingsNavigation()
    }

    #if os(macOS)
    private var nativeMacContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Acknowledgements")
                        .font(.largeTitle.bold())
                    Text("Open-source software that makes BisonNotes AI possible.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                acknowledgementCard(title: "Direct Dependencies", systemImage: "shippingbox") {
                    ForEach(Array(directDependencies.enumerated()), id: \.element.id) { index, dependency in
                        if index > 0 {
                            Divider()
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(dependency.name)
                                    .font(.headline)
                                Spacer()
                                Text(dependency.license)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }

                            Text(dependency.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Link(dependency.linkText, destination: dependency.url)
                                .font(.caption)
                        }
                        .padding(.vertical, 3)
                    }
                }

                acknowledgementCard(title: "Transitive Dependencies", systemImage: "square.stack.3d.up") {
                    DisclosureGroup(isExpanded: $showTransitiveDependencies) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(transitiveDependencyGroups) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(group.title)
                                        .font(.subheadline.weight(.semibold))

                                    LazyVGrid(
                                        columns: [
                                            GridItem(.flexible(), alignment: .leading),
                                            GridItem(.flexible(), alignment: .leading)
                                        ],
                                        alignment: .leading,
                                        spacing: 7
                                    ) {
                                        ForEach(group.projects) { project in
                                            Link(project.name, destination: project.url)
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        Text(showTransitiveDependencies ? "Hide dependency list" : "Show dependency list")
                            .fontWeight(.medium)
                    }

                    Text(
                        "These projects arrive through the direct dependencies above. "
                            + "The software dependencies are licensed as shown; follow each repository link "
                            + "for complete terms."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                acknowledgementCard(title: "Downloaded Model Assets", systemImage: "arrow.down.circle") {
                    modelAssetLinks
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Acknowledgements")
    }

    private func acknowledgementCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.indigo)

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    #endif

    @ViewBuilder
    private var modelAssetLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Speaker-label model assets are downloaded separately from software dependencies and are not bundled "
                    + "application code."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(
                "Offline VBx / Pyannote Core ML assets — CC BY 4.0 parent Pyannote; FluidAudio SDK Apache 2.0",
                destination: URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml")!
            )
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            Link(
                "LS-EEND DIHARD3 Core ML assets — MIT; upstream dataset terms remain",
                destination: URL(string: "https://huggingface.co/FluidInference/ls-eend-coreml")!
            )
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            Link(
                "LS-EEND paper — Long-Form Streaming End-to-End Neural Diarization",
                destination: URL(string: "https://arxiv.org/abs/2410.06670")!
            )
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            Link(
                "LS-EEND source project — FS-EEND",
                destination: URL(string: "https://github.com/Audio-WestlakeU/FS-EEND")!
            )
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "Retain the LS-EEND original paper/source credits and upstream dataset terms from the model card. "
                    + "BisonNotes does not redistribute evaluation fixtures."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DependencyCard: Identifiable {
    let name: String
    let description: String
    let license: String
    let linkText: String
    let url: URL

    var id: String { name }
}

private struct DependencyGroup: Identifiable {
    let title: String
    let projects: [TransitiveProject]

    var id: String { title }
}

private struct TransitiveProject: Identifiable {
    let name: String
    let url: URL

    var id: String { name }
}

private let directDependencies: [DependencyCard] = [
    DependencyCard(
        name: "Textual",
        description: "Markdown rendering library for summaries, transcripts, and formatted content.",
        license: "MIT",
        linkText: "gonzalezreal/Textual",
        url: URL(string: "https://github.com/gonzalezreal/Textual")!
    ),
    DependencyCard(
        name: "FluidAudio",
        description: "On-device speech framework powering Parakeet transcription.",
        license: "Apache 2.0",
        linkText: "FluidInference/FluidAudio",
        url: URL(string: "https://github.com/FluidInference/FluidAudio")!
    ),
    DependencyCard(
        name: "MLX Swift / MLX Swift LM",
        description: "Apple Silicon ML framework and language-model utilities used for on-device summarization "
            + "with Ternary Bonsai models.",
        license: "MIT",
        linkText: "ml-explore/mlx-swift + mlx-swift-lm",
        url: URL(string: "https://github.com/ml-explore/mlx-swift")!
    ),
    DependencyCard(
        name: "llama.cpp",
        description: "C/C++ inference engine for on-device LLM processing with Metal-accelerated summarization.",
        license: "MIT",
        linkText: "ggerganov/llama.cpp",
        url: URL(string: "https://github.com/ggerganov/llama.cpp")!
    ),
    DependencyCard(
        name: "Swift Transformers",
        description: "Hugging Face tokenizers and transformer utilities used by local model pipelines.",
        license: "Apache 2.0",
        linkText: "huggingface/swift-transformers",
        url: URL(string: "https://github.com/huggingface/swift-transformers")!
    )
]

private let transitiveDependencyGroups: [DependencyGroup] = [
    DependencyGroup(
        title: "Swift and Community Libraries",
        projects: [
            TransitiveProject(name: "Swift NIO", url: URL(string: "https://github.com/apple/swift-nio")!),
            TransitiveProject(name: "Swift Crypto", url: URL(string: "https://github.com/apple/swift-crypto")!),
            TransitiveProject(
                name: "Swift Collections", url: URL(string: "https://github.com/apple/swift-collections")!
            ),
            TransitiveProject(name: "Swift Atomics", url: URL(string: "https://github.com/apple/swift-atomics")!),
            TransitiveProject(name: "Swift System", url: URL(string: "https://github.com/apple/swift-system")!),
            TransitiveProject(name: "Swift Numerics", url: URL(string: "https://github.com/apple/swift-numerics")!),
            TransitiveProject(name: "Swift ASN1", url: URL(string: "https://github.com/apple/swift-asn1")!),
            TransitiveProject(name: "Swift Jinja", url: URL(string: "https://github.com/huggingface/swift-jinja")!),
            TransitiveProject(
                name: "Swift HuggingFace", url: URL(string: "https://github.com/huggingface/swift-huggingface")!
            ),
            TransitiveProject(name: "SwiftUI Math", url: URL(string: "https://github.com/gonzalezreal/swiftui-math")!),
            TransitiveProject(name: "EventSource", url: URL(string: "https://github.com/mattt/EventSource")!),
            TransitiveProject(name: "yyjson", url: URL(string: "https://github.com/ibireme/yyjson")!),
            TransitiveProject(
                name: "Swift Concurrency Extras",
                url: URL(string: "https://github.com/pointfreeco/swift-concurrency-extras")!
            )
        ]
    )
]
