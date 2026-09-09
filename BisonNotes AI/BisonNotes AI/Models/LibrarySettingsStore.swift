import Foundation
import GRDB

/// The primitive values allowed through the migration-owned settings boundary.
///
/// This is deliberately narrower than `UserDefaults`' arbitrary property-list
/// surface. Arrays and dictionaries require an explicit schema before they can
/// be copied; unsupported values fail loudly instead of being silently lost.
enum LibrarySettingValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case real(Double)
    case bool(Bool)
    case data(Data)
    case date(Date)
}

struct LibrarySettingsSnapshot: Equatable, Sendable {
    let values: [String: LibrarySettingValue]
}

protocol LibrarySettingsStore: Sendable {
    func read() async throws -> LibrarySettingsSnapshot
    func apply(_ snapshot: LibrarySettingsSnapshot) async throws
}

enum LibrarySettingsStoreError: LocalizedError, Equatable {
    case invalidKey(String)
    case disallowedKey(String)
    case unsupportedValue(key: String, type: String)
    case nonFiniteValue(key: String)

    var errorDescription: String? {
        switch self {
        case .invalidKey(let key):
            return "The settings key is invalid: \(key)"
        case .disallowedKey(let key):
            return "The settings key is outside the migration allowlist: \(key)"
        case .unsupportedValue(let key, let type):
            return "The settings value for \(key) has unsupported type \(type)."
        case .nonFiniteValue(let key):
            return "The settings value for \(key) is not finite."
        }
    }
}

/// A UserDefaults adapter that can only touch an explicit allowlist.
///
/// The migration must not copy an entire defaults domain: credentials and
/// device-specific state remain outside this contract. The production caller
/// will provide the reviewed key set; tests use a small synthetic set.
final class UserDefaultsLibrarySettingsStore: LibrarySettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let allowedKeys: Set<String>

    init(defaults: UserDefaults = .standard, allowedKeys: [String]) throws {
        let normalizedKeys = Set(allowedKeys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard !normalizedKeys.isEmpty, !normalizedKeys.contains("") else {
            throw LibrarySettingsStoreError.invalidKey("<empty allowlist>")
        }
        self.defaults = defaults
        self.allowedKeys = normalizedKeys
    }

    func read() async throws -> LibrarySettingsSnapshot {
        var values: [String: LibrarySettingValue] = [:]
        for key in allowedKeys.sorted() {
            guard let rawValue = defaults.object(forKey: key) else { continue }
            values[key] = try Self.decode(rawValue, key: key)
        }
        return LibrarySettingsSnapshot(values: values)
    }

    func apply(_ snapshot: LibrarySettingsSnapshot) async throws {
        for key in snapshot.values.keys.sorted() {
            try validate(key: key)
            guard let value = snapshot.values[key] else { continue }
            try Self.write(value, forKey: key, to: defaults)
        }
    }

    private func validate(key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibrarySettingsStoreError.invalidKey(key)
        }
        guard allowedKeys.contains(key) else {
            throw LibrarySettingsStoreError.disallowedKey(key)
        }
    }

    private static func decode(_ rawValue: Any, key: String) throws -> LibrarySettingValue {
        if let value = rawValue as? String {
            return .string(value)
        }
        if let value = rawValue as? Data {
            return .data(value)
        }
        if let value = rawValue as? Date {
            return .date(value)
        }
        if let value = rawValue as? NSNumber {
            let objcType = String(cString: value.objCType)
            if objcType == "c" || objcType == "B" {
                return .bool(value.boolValue)
            }
            if objcType == "f" || objcType == "d" {
                let realValue = value.doubleValue
                guard realValue.isFinite else {
                    throw LibrarySettingsStoreError.nonFiniteValue(key: key)
                }
                return .real(realValue)
            }
            return .integer(value.int64Value)
        }

        throw LibrarySettingsStoreError.unsupportedValue(
            key: key,
            type: String(describing: type(of: rawValue))
        )
    }

    private static func write(
        _ value: LibrarySettingValue,
        forKey key: String,
        to defaults: UserDefaults
    ) throws {
        switch value {
        case .string(let value):
            defaults.set(value, forKey: key)
        case .integer(let value):
            defaults.set(value, forKey: key)
        case .real(let value):
            guard value.isFinite else {
                throw LibrarySettingsStoreError.nonFiniteValue(key: key)
            }
            defaults.set(value, forKey: key)
        case .bool(let value):
            defaults.set(value, forKey: key)
        case .data(let value):
            defaults.set(value, forKey: key)
        case .date(let value):
            defaults.set(value, forKey: key)
        }
    }
}

/// SQLite settings adapter with the same explicit allowlist semantics as the
/// UserDefaults adapter. The table itself is durable, but callers still decide
/// which reviewed keys may cross the migration boundary.
struct SQLiteLibrarySettingsStore: LibrarySettingsStore, Sendable {
    let store: SQLiteLibraryStore
    private let allowedKeys: Set<String>

    init(store: SQLiteLibraryStore, allowedKeys: [String]) throws {
        let normalizedKeys = Set(allowedKeys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard !normalizedKeys.isEmpty, !normalizedKeys.contains("") else {
            throw LibrarySettingsStoreError.invalidKey("<empty allowlist>")
        }
        self.store = store
        self.allowedKeys = normalizedKeys
    }

    func read() async throws -> LibrarySettingsSnapshot {
        let snapshot = try await store.readLibrarySettings()
        return LibrarySettingsSnapshot(
            values: snapshot.values.filter { allowedKeys.contains($0.key) }
        )
    }

    func apply(_ snapshot: LibrarySettingsSnapshot) async throws {
        for key in snapshot.values.keys.sorted() {
            guard allowedKeys.contains(key) else {
                throw LibrarySettingsStoreError.disallowedKey(key)
            }
        }
        try await store.applyLibrarySettings(snapshot)
    }
}
