import CryptoKit
import Foundation

enum SQLiteMigrationRecoveryReporter {
    static let recoveryCategory = "sqlite-migration-recovery-report"

    static func report(
        for error: SQLiteMigrationImportError,
        snapshot: SQLiteMigrationSourceSnapshot,
        runID: String? = nil,
        at date: Date = Date()
    ) -> SQLiteMigrationRecoveryReport {
        SQLiteMigrationRecoveryReport(
            runID: runID,
            sourceModel: safeLabel(snapshot.sourceModel, fallback: "unknown-model"),
            sourceFingerprint: safeLabel(
                snapshot.sourceFingerprint,
                fallback: "unknown-fingerprint"
            ),
            generatedAt: date,
            issues: [issue(for: error)]
        )
    }

    static func validationReport(
        for snapshot: SQLiteMigrationSourceSnapshot,
        at date: Date = Date()
    ) -> SQLiteMigrationRecoveryReport {
        do {
            try SQLiteMigrationImportSupport.validate(snapshot: snapshot)
            return baseReport(for: snapshot, at: date, issues: [])
        } catch let error as SQLiteMigrationImportError {
            return report(for: error, snapshot: snapshot, at: date)
        } catch {
            return baseReport(
                for: snapshot,
                at: date,
                issues: [
                    SQLiteMigrationRecoveryIssue(
                        kind: .invalidSnapshot,
                        entity: nil,
                        column: nil,
                        identifierDigest: nil,
                        detail: "snapshot validation failed"
                    )
                ]
            )
        }
    }

    static func report(
        for verification: SQLiteMigrationVerificationReport,
        snapshot: SQLiteMigrationSourceSnapshot,
        at date: Date = Date()
    ) -> SQLiteMigrationRecoveryReport {
        let issues = verification.mismatches.map { mismatch in
            SQLiteMigrationRecoveryIssue(
                kind: .verificationMismatch,
                entity: mismatch.entity?.rawValue,
                column: mismatch.column,
                identifierDigest: digest(mismatch.storageID),
                detail: mismatch.kind.rawValue
            )
        }
        return baseReport(for: snapshot, at: date, issues: issues)
    }

    private static func baseReport(
        for snapshot: SQLiteMigrationSourceSnapshot,
        at date: Date,
        issues: [SQLiteMigrationRecoveryIssue]
    ) -> SQLiteMigrationRecoveryReport {
        SQLiteMigrationRecoveryReport(
            runID: snapshot.migrationRunID,
            sourceModel: safeLabel(snapshot.sourceModel, fallback: "unknown-model"),
            sourceFingerprint: safeLabel(
                snapshot.sourceFingerprint,
                fallback: "unknown-fingerprint"
            ),
            generatedAt: date,
            issues: issues
        )
    }

    private static func issue(
        for error: SQLiteMigrationImportError
    ) -> SQLiteMigrationRecoveryIssue {
        switch error {
        case .invalidSnapshot:
            return issue(kind: .invalidSnapshot, detail: "snapshot validation failed")
        case .runNotFound(let runID):
            return issue(
                kind: .runConfigurationMismatch,
                identifierDigest: digest(runID),
                detail: "migration run was not found"
            )
        case .runConfigurationMismatch:
            return issue(
                kind: .runConfigurationMismatch,
                detail: "migration run configuration differs from the source snapshot"
            )
        case .destinationRowConflict(let entity, let storageID, _):
            return issue(
                kind: .destinationConflict,
                entity: entity.rawValue,
                identifierDigest: digest(storageID),
                detail: "destination row conflicts with the source snapshot"
            )
        case .sourceRowConflict(let entity, let sourceObjectID, _):
            return issue(
                kind: .sourceConflict,
                entity: entity.rawValue,
                identifierDigest: digest(sourceObjectID),
                detail: "source row map conflicts with the destination"
            )
        case .runNotResumable:
            return issue(
                kind: .runStateConflict,
                detail: "migration run is not resumable"
            )
        case .incompleteImport:
            return issue(
                kind: .incompleteImport,
                detail: "metadata import did not reach the source row count"
            )
        }
    }

    private static func issue(
        kind: SQLiteMigrationRecoveryIssueKind,
        entity: String? = nil,
        identifierDigest: String? = nil,
        detail: String
    ) -> SQLiteMigrationRecoveryIssue {
        SQLiteMigrationRecoveryIssue(
            kind: kind,
            entity: entity,
            column: nil,
            identifierDigest: identifierDigest,
            detail: detail
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func safeLabel(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }
}
