//
//  AcknowledgementsView.swift
//  BisonNotes AI
//

import SwiftUI

struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showTransitiveDependencies = false

    var body: some View {
        NavigationStack {
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

                Section("Forked Repositories") {
                    Link("github.com/bisonbet", destination: URL(string: "https://github.com/bisonbet")!)
                        .font(.caption)
                    ForEach(forkedRepositories) { repository in
                        VStack(alignment: .leading, spacing: 4) {
                            Link(repository.name, destination: repository.url)
                            Text(repository.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
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
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
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

private struct AcknowledgementLink: Identifiable {
    let name: String
    let description: String
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
        name: "Textual (swift-markdown-ui)",
        description: "Markdown rendering library for summaries and transcripts with custom styling adjustments.",
        license: "MIT",
        linkText: "gonzalezreal/swift-markdown-ui",
        url: URL(string: "https://github.com/gonzalezreal/swift-markdown-ui")!
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

private let forkedRepositories: [AcknowledgementLink] = [
    AcknowledgementLink(
        name: "bisonbet/textual",
        description: "Fork of gonzalezreal/swift-markdown-ui.",
        url: URL(string: "https://github.com/bisonbet/textual")!
    )
]

private let transitiveDependencyGroups: [DependencyGroup] = [
    DependencyGroup(
        title: "Apple Swift Server Libraries",
        projects: [
            TransitiveProject(name: "Swift NIO", url: URL(string: "https://github.com/apple/swift-nio")!),
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
            TransitiveProject(name: "Swift Distributed Tracing", url: URL(string: "https://github.com/apple/swift-distributed-tracing")!),
            TransitiveProject(name: "Swift Service Context", url: URL(string: "https://github.com/apple/swift-service-context")!)
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
            TransitiveProject(name: "Swift Concurrency Extras", url: URL(string: "https://github.com/pointfreeco/swift-concurrency-extras")!)
        ]
    )
]

