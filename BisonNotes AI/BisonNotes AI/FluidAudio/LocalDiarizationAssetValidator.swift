import Foundation

enum LocalDiarizationAssetValidator {
    // These are the required artifacts emitted by Core ML for the pinned
    // FluidAudio compiled models. A partially populated bundle must not report
    // Ready merely because its directory contains one nonempty file.
    private static let requiredCompiledModelFiles = [
        "model.mil",
        "metadata.json",
        "coremldata.bin"
    ]

    static func compiledModelBundleIsValid(
        at url: URL,
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
        metadataJSONIsValid(
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
