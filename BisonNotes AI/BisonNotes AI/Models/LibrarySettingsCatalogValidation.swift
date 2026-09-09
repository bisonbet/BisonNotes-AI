import Foundation

private extension LibrarySettingValue {
    var kind: LibrarySettingValueKind {
        switch self {
        case .string: return .string
        case .integer: return .integer
        case .real: return .real
        case .bool: return .bool
        case .data: return .data
        case .date: return .date
        }
    }
}

extension LibrarySettingsCatalog {
    static func validateMigratableSnapshot(_ snapshot: LibrarySettingsSnapshot) throws {
        for (key, value) in snapshot.values.sorted(by: { $0.key < $1.key }) {
            guard let definition = definition(for: key) else {
                throw LibrarySettingsCatalogError.unclassifiedKeys([key])
            }
            guard definition.disposition == .blockingMetadata else {
                throw LibrarySettingsCatalogError.nonMigratableKey(key)
            }
            guard definition.valueKind == value.kind else {
                throw LibrarySettingsCatalogError.valueKindMismatch(
                    key: key,
                    expected: definition.valueKind,
                    actual: value.kind
                )
            }
            try validateMigratableValue(value, forKey: key)
        }
    }

    private static let integerRanges: [String: ClosedRange<Int64>] = [
        "summaryDetailLevel": 0...2,
        "summaryThinkingLevel": 0...1,
        "ollamaPort": 1...65_535,
        "whisperPort": 1...65_535,
        "mlxSwiftMaxTokens": 1...1_000_000,
        "openAICompatibleMaxTokens": 1...1_000_000,
        "googleAIStudioMaxTokens": 1...1_000_000,
        "mistralMaxTokens": 1...1_000_000,
        "ollamaMaxTokens": 1...1_000_000
    ]

    private static let realRanges: [String: ClosedRange<Double>] = [
        "summarizationTimeout": 30...600,
        "openAICompatibleTemperature": 0...1,
        "googleAIStudioTemperature": 0...1,
        "mistralTemperature": 0...1,
        "ollamaTemperature": 0...1,
        "mlxSwiftTemperature": 0...1
    ]

    private static let allowedStringValues: [String: Set<String>] = [
        "user_preference_time_format": ["12h", "24h"],
        "fluidAudioSelectedModelVersion": ["v2", "v3"],
        "whisperProtocol": ["REST API", "Wyoming"]
    ]

    private static let endpointKeys: Set<String> = [
        "openAICompatibleBaseURL",
        "mistralBaseURL",
        "ollamaServerURL",
        "whisperServerURL"
    ]

    private static func validateMigratableValue(
        _ value: LibrarySettingValue,
        forKey key: String
    ) throws {
        if case .real(let number) = value, !number.isFinite {
            throw LibrarySettingsCatalogError.invalidValue(key: key, reason: "value is not finite")
        }
        if let range = integerRanges[key] {
            try validateInteger(value, key: key, range: range)
        } else if let range = realRanges[key] {
            try validateReal(value, key: key, range: range)
        } else if let allowed = allowedStringValues[key] {
            try validateString(value, key: key, allowed: allowed)
        } else if endpointKeys.contains(key) {
            try validateEndpoint(value, key: key)
        }
    }

    private static func validateInteger(
        _ value: LibrarySettingValue,
        key: String,
        range: ClosedRange<Int64>
    ) throws {
        guard case .integer(let number) = value, range.contains(number) else {
            throw LibrarySettingsCatalogError.invalidValue(
                key: key,
                reason: "expected integer in \(range.lowerBound)...\(range.upperBound)"
            )
        }
    }

    private static func validateReal(
        _ value: LibrarySettingValue,
        key: String,
        range: ClosedRange<Double>
    ) throws {
        guard case .real(let number) = value, number.isFinite, range.contains(number) else {
            throw LibrarySettingsCatalogError.invalidValue(
                key: key,
                reason: "expected finite real in \(range.lowerBound)...\(range.upperBound)"
            )
        }
    }

    private static func validateString(
        _ value: LibrarySettingValue,
        key: String,
        allowed: Set<String>
    ) throws {
        guard case .string(let string) = value, allowed.contains(string) else {
            throw LibrarySettingsCatalogError.invalidValue(
                key: key,
                reason: "expected one of \(allowed.sorted().joined(separator: ", "))"
            )
        }
    }

    private static func validateEndpoint(
        _ value: LibrarySettingValue,
        key: String
    ) throws {
        guard case .string(let rawValue) = value else {
            throw LibrarySettingsCatalogError.invalidValue(key: key, reason: "expected URL string")
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw LibrarySettingsCatalogError.invalidValue(
                key: key,
                reason: "expected an HTTP(S) endpoint without embedded credentials"
            )
        }
    }
}
