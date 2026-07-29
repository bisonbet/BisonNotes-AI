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
                    Text("These are brought in through AWS SDK and other direct dependencies. All dependencies are MIT or Apache 2.0 licensed. See each project repository for full terms.")
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
                            + "Each is licensed under MIT or Apache 2.0; follow its repository link for complete terms."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        description: "Apple Silicon ML framework and language-model utilities used for on-device summarization with Ternary Bonsai models.",
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
        name: "AWS SDK for Swift",
        description: "Cloud SDK powering AWS Bedrock, Transcribe, and S3 integrations.",
        license: "Apache 2.0",
        linkText: "awslabs/aws-sdk-swift",
        url: URL(string: "https://github.com/awslabs/aws-sdk-swift")!
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
        title: "Apple Swift Server Libraries",
        projects: [
            TransitiveProject(name: "Swift NIO", url: URL(string: "https://github.com/apple/swift-nio")!),
            TransitiveProject(name: "Swift NIO Extras", url: URL(string: "https://github.com/apple/swift-nio-extras")!),
            TransitiveProject(name: "Swift NIO HTTP/2", url: URL(string: "https://github.com/apple/swift-nio-http2")!),
            TransitiveProject(name: "Swift NIO SSL", url: URL(string: "https://github.com/apple/swift-nio-ssl")!),
            TransitiveProject(name: "Swift NIO Transport Services", url: URL(string: "https://github.com/apple/swift-nio-transport-services")!),
            TransitiveProject(name: "Swift Crypto", url: URL(string: "https://github.com/apple/swift-crypto")!),
            TransitiveProject(name: "Swift Protobuf", url: URL(string: "https://github.com/apple/swift-protobuf")!),
            TransitiveProject(name: "Swift Collections", url: URL(string: "https://github.com/apple/swift-collections")!),
            TransitiveProject(name: "Swift Algorithms", url: URL(string: "https://github.com/apple/swift-algorithms")!),
            TransitiveProject(name: "Swift Log", url: URL(string: "https://github.com/apple/swift-log")!),
            TransitiveProject(name: "Swift Metrics", url: URL(string: "https://github.com/apple/swift-metrics")!),
            TransitiveProject(name: "Swift Atomics", url: URL(string: "https://github.com/apple/swift-atomics")!),
            TransitiveProject(name: "Swift System", url: URL(string: "https://github.com/apple/swift-system")!),
            TransitiveProject(name: "Swift Async Algorithms", url: URL(string: "https://github.com/apple/swift-async-algorithms")!),
            TransitiveProject(name: "Swift Argument Parser", url: URL(string: "https://github.com/apple/swift-argument-parser")!),
            TransitiveProject(name: "Swift Numerics", url: URL(string: "https://github.com/apple/swift-numerics")!),
            TransitiveProject(name: "Swift Certificates", url: URL(string: "https://github.com/apple/swift-certificates")!),
            TransitiveProject(name: "Swift ASN1", url: URL(string: "https://github.com/apple/swift-asn1")!),
            TransitiveProject(name: "Swift HTTP Types", url: URL(string: "https://github.com/apple/swift-http-types")!),
            TransitiveProject(name: "Swift HTTP Structured Headers", url: URL(string: "https://github.com/apple/swift-http-structured-headers")!),
            TransitiveProject(name: "Swift Distributed Tracing", url: URL(string: "https://github.com/apple/swift-distributed-tracing")!),
            TransitiveProject(name: "Swift Service Context", url: URL(string: "https://github.com/apple/swift-service-context")!),
            TransitiveProject(name: "Swift Configuration", url: URL(string: "https://github.com/apple/swift-configuration")!)
        ]
    ),
    DependencyGroup(
        title: "Community and Infrastructure",
        projects: [
            TransitiveProject(name: "Async HTTP Client", url: URL(string: "https://github.com/swift-server/async-http-client")!),
            TransitiveProject(name: "Swift Service Lifecycle", url: URL(string: "https://github.com/swift-server/swift-service-lifecycle")!),
            TransitiveProject(name: "gRPC Swift", url: URL(string: "https://github.com/grpc/grpc-swift")!),
            TransitiveProject(name: "OpenTelemetry Swift", url: URL(string: "https://github.com/open-telemetry/opentelemetry-swift")!),
            TransitiveProject(name: "AWS CRT Swift", url: URL(string: "https://github.com/awslabs/aws-crt-swift")!),
            TransitiveProject(name: "Smithy Swift", url: URL(string: "https://github.com/smithy-lang/smithy-swift")!),
            TransitiveProject(name: "Swift Jinja", url: URL(string: "https://github.com/huggingface/swift-jinja")!),
            TransitiveProject(name: "Swift HuggingFace", url: URL(string: "https://github.com/huggingface/swift-huggingface")!),
            TransitiveProject(name: "SwiftUI Math", url: URL(string: "https://github.com/gonzalezreal/swiftui-math")!),
            TransitiveProject(name: "EventSource", url: URL(string: "https://github.com/mattt/EventSource")!),
            TransitiveProject(name: "yyjson", url: URL(string: "https://github.com/ibireme/yyjson")!),
            TransitiveProject(name: "Swift Concurrency Extras", url: URL(string: "https://github.com/pointfreeco/swift-concurrency-extras")!)
        ]
    )
]
