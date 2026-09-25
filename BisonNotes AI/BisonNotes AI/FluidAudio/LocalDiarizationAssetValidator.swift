import Foundation

/// Where the Nemotron 3 preset's files must sit inside its method cache, and
/// what they must contain. Built from the SDK's constants in production and
/// from literals in tests, so the validator itself stays SDK-independent.
struct Nemotron3AssetLayout: Equatable, Sendable {
    let repoDirectory: URL
    let modelBundle: URL
    let silenceEmbedding: URL
    let preEncodeProjection: URL
    let weightsVersionMarker: URL
    let expectedWeightsVersion: String

    /// 512 fp32 values.
    static let silenceEmbeddingByteCount = 512 * MemoryLayout<Float>.size
    /// The [1024, 512] fp32 FeatureStacking projection split-graph presets need.
    static let preEncodeProjectionByteCount = 1024 * 512 * MemoryLayout<Float>.size
}

enum LocalDiarizationAssetValidator {
    // These are the required artifacts emitted by Core ML for the pinned
    // FluidAudio compiled models. A partially populated bundle must not report
    // Ready merely because its directory contains one nonempty file.
    private static let requiredCompiledModelFiles = [
        "model.mil",
        "coremldata.bin"
    ]

    /// `requiresMetadata` is false only for bundles published without a
    /// `metadata.json` (the Nemotron 3 conversions); every other check still
    /// applies to them.
    static func compiledModelBundleIsValid(
        at url: URL,
        requiresMetadata: Bool = true,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              url.pathExtension == "mlmodelc"
        else {
            return false
        }

        guard requiredCompiledModelFiles.allSatisfy({ fileName in
            isNonEmptyRegularFile(
                at: url.appendingPathComponent(fileName, isDirectory: false),
                fileManager: fileManager
            )
        }),
        !requiresMetadata || metadataJSONIsValid(
            at: url.appendingPathComponent("metadata.json", isDirectory: false),
            fileManager: fileManager
        ),
        containsNonEmptyRegularFile(
            in: url.appendingPathComponent("weights", isDirectory: true),
            fileManager: fileManager
        )
        else {
            return false
        }

        return true
    }

    static func pldaParametersAreValid(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let tensors = root["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String,
              let decoded = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              decoded.count >= MemoryLayout<Float>.size
        else {
            return false
        }
        return true
    }

    /// Ready only when the compiled preset, both fp32 assets at their exact
    /// sizes, and a weights marker naming the checkpoint the pinned SDK expects
    /// are all present. A cache from a superseded checkpoint reports Download
    /// Required rather than feeding old weights to newer inference code.
    static func nemotron3AssetsAreValid(
        _ layout: Nemotron3AssetLayout,
        fileManager: FileManager = .default
    ) -> Bool {
        guard compiledModelBundleIsValid(
            at: layout.modelBundle,
            requiresMetadata: false,
            fileManager: fileManager
        ),
        regularFileSize(at: layout.silenceEmbedding, fileManager: fileManager)
            == Nemotron3AssetLayout.silenceEmbeddingByteCount,
        regularFileSize(at: layout.preEncodeProjection, fileManager: fileManager)
            == Nemotron3AssetLayout.preEncodeProjectionByteCount,
        let marker = try? String(contentsOf: layout.weightsVersionMarker, encoding: .utf8)
        else {
            return false
        }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == layout.expectedWeightsVersion
    }

    /// Read through the file manager rather than `URL.resourceValues`, which
    /// caches per URL instance and would keep reporting a size the file no
    /// longer has when a stored layout is checked again after a download.
    private static func regularFileSize(at url: URL, fileManager: FileManager) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.intValue
    }

    private static func isNonEmptyRegularFile(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return false
        }
        return values.isRegularFile == true
            && (values.fileSize ?? 0) > 0
            && fileManager.fileExists(atPath: url.path)
    }

    private static func containsNonEmptyRegularFile(
        in directoryURL: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return false
        }

        for case let fileURL as URL in enumerator
            where isNonEmptyRegularFile(at: fileURL, fileManager: fileManager) {
            return true
        }
        return false
    }

    private static func metadataJSONIsValid(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let data = fileManager.contents(atPath: url.path),
              !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }

        switch object {
        case let array as [Any]:
            return !array.isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        default:
            return false
        }
    }
}
