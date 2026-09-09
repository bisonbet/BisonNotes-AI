import Foundation
import GRDB

enum SQLiteLibraryStoreSchema {
    static let initialSchemaVersion = 1
    static let settingsSchemaVersion = 2
    static let changesSchemaVersion = 3

    static func createInitial(in database: Database) throws {
        try createMetadata(in: database)
        try createRecordings(in: database)
        try createSummaries(in: database)
        try createTranscripts(in: database)
        try createProcessingJobs(in: database)
        try createArchiveLocations(in: database)
        try createPendingCloudMutations(in: database)
        try SQLiteLibraryStoreOperationalSchema.create(in: database)
    }

    static func addSettings(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE library_settings (
                key TEXT NOT NULL PRIMARY KEY CHECK (key <> ''),
                valueType TEXT NOT NULL CHECK (valueType IN ('string', 'integer', 'real', 'bool', 'data', 'date')),
                stringValue TEXT,
                integerValue INTEGER,
                realValue REAL,
                blobValue BLOB,
                updatedAt REAL NOT NULL,
                CHECK (
                    (valueType = 'string' AND stringValue IS NOT NULL
                        AND integerValue IS NULL AND realValue IS NULL AND blobValue IS NULL) OR
                    (valueType IN ('integer', 'bool') AND stringValue IS NULL
                        AND integerValue IS NOT NULL AND realValue IS NULL AND blobValue IS NULL) OR
                    (valueType IN ('real', 'date') AND stringValue IS NULL
                        AND integerValue IS NULL AND realValue IS NOT NULL AND blobValue IS NULL) OR
                    (valueType = 'data' AND stringValue IS NULL
                        AND integerValue IS NULL AND realValue IS NULL AND blobValue IS NOT NULL)
                )
            )
            """)

        try database.execute(
            sql: """
            UPDATE library_metadata
            SET schemaVersion = ?, updatedAt = ?
            WHERE id = 1
            """,
            arguments: [
                settingsSchemaVersion,
                Date().timeIntervalSinceReferenceDate
            ]
        )
    }

    static func addChanges(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE library_changes (
                revision INTEGER NOT NULL PRIMARY KEY,
                entity TEXT NOT NULL CHECK (entity IN (
                    'recording', 'transcript', 'summary', 'processingJob',
                    'archiveLocation', 'pendingCloudMutation', 'setting'
                )),
                storageID TEXT NOT NULL,
                operation TEXT NOT NULL CHECK (operation IN ('inserted', 'updated', 'deleted')),
                committedAt REAL NOT NULL
            )
            """)

        try database.execute(
            sql: """
            CREATE INDEX library_changes_by_entity
            ON library_changes (entity, storageID, revision)
            """
        )

        try database.execute(
            sql: """
            UPDATE library_metadata
            SET schemaVersion = ?, updatedAt = ?
            WHERE id = 1
            """,
            arguments: [
                changesSchemaVersion,
                Date().timeIntervalSinceReferenceDate
            ]
        )
    }

    private static func createMetadata(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE schema_migrations (
                version INTEGER NOT NULL UNIQUE CHECK (version > 0),
                identifier TEXT NOT NULL PRIMARY KEY,
                appliedAt REAL NOT NULL
            )
            """)

        try database.execute(sql: """
            CREATE TABLE library_metadata (
                id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
                libraryID TEXT NOT NULL,
                generationID TEXT NOT NULL,
                schemaVersion INTEGER NOT NULL,
                minimumReaderVersion INTEGER NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL
            )
            """)

        let now = Date().timeIntervalSinceReferenceDate
        try database.execute(
            sql: """
            INSERT INTO library_metadata (
                id, libraryID, generationID, schemaVersion,
                minimumReaderVersion, revision, createdAt, updatedAt
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                1,
                UUID().uuidString,
                UUID().uuidString,
                initialSchemaVersion,
                SQLiteLibraryStore.minimumReaderVersion,
                0,
                now,
                now
            ]
        )
    }

    private static func createRecordings(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE recordings (
                storageID TEXT NOT NULL PRIMARY KEY,
                audioQuality TEXT,
                createdAt REAL,
                duration REAL,
                fileSize INTEGER,
                id TEXT,
                isCloudSyncDisabled INTEGER,
                lastModified REAL,
                locationAccuracy REAL,
                locationAddress TEXT,
                locationLatitude REAL,
                locationLongitude REAL,
                locationTimestamp REAL,
                recordingDate REAL,
                recordingName TEXT,
                recordingURL TEXT,
                summaryId TEXT,
                summaryStatus TEXT,
                transcriptId TEXT,
                transcriptionStatus TEXT,
                isArchived INTEGER,
                archivedAt REAL,
                archiveNote TEXT
            )
            """)
    }

    private static func createSummaries(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE summaries (
                storageID TEXT NOT NULL PRIMARY KEY,
                aiMethod TEXT,
                compressionRatio REAL,
                confidence REAL,
                contentType TEXT,
                generatedAt REAL,
                id TEXT,
                originalLength INTEGER,
                processingTime REAL,
                recordingStorageID TEXT,
                recordingId TEXT,
                reminders TEXT,
                summary TEXT,
                tasks TEXT,
                titles TEXT,
                transcriptStorageID TEXT,
                transcriptId TEXT,
                version INTEGER,
                wordCount INTEGER,
                FOREIGN KEY (recordingStorageID) REFERENCES recordings(storageID) ON DELETE RESTRICT,
                FOREIGN KEY (transcriptStorageID) REFERENCES transcripts(storageID) ON DELETE RESTRICT
            )
            """)
    }

    private static func createTranscripts(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE transcripts (
                storageID TEXT NOT NULL PRIMARY KEY,
                confidence REAL,
                createdAt REAL,
                engine TEXT,
                id TEXT,
                lastModified REAL,
                processingTime REAL,
                recordingStorageID TEXT,
                recordingId TEXT,
                segments TEXT,
                speakerMappings TEXT,
                FOREIGN KEY (recordingStorageID) REFERENCES recordings(storageID) ON DELETE RESTRICT
            )
            """)
    }

    private static func createProcessingJobs(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE processing_jobs (
                storageID TEXT NOT NULL PRIMARY KEY,
                completionTime REAL,
                engine TEXT,
                error TEXT,
                id TEXT,
                jobType TEXT,
                lastModified REAL,
                modelName TEXT,
                progress REAL,
                recordingName TEXT,
                recordingURL TEXT,
                recordingStorageID TEXT,
                startTime REAL,
                status TEXT,
                FOREIGN KEY (recordingStorageID) REFERENCES recordings(storageID) ON DELETE RESTRICT
            )
            """)
    }

    private static func createArchiveLocations(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE archive_locations (
                storageID TEXT NOT NULL PRIMARY KEY,
                bookmarkData BLOB,
                destinationURLString TEXT,
                displayName TEXT,
                exportedAt REAL,
                exportedFilename TEXT,
                fileSize INTEGER,
                id TEXT,
                lastVerifiedAt REAL,
                providerDisplayName TEXT,
                recordingId TEXT,
                status TEXT
            )
            """)
    }

    private static func createPendingCloudMutations(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE pending_cloud_mutations (
                storageID TEXT NOT NULL PRIMARY KEY,
                kind TEXT NOT NULL,
                payload BLOB,
                recordingId TEXT,
                requestedAt REAL,
                targetId TEXT NOT NULL,
                version INTEGER NOT NULL
            )
            """)
    }
}
