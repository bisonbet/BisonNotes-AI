import GRDB

enum SQLiteLibraryStoreOperationalSchema {
    static func create(in database: Database) throws {
        try createMigrationTables(in: database)
        try createAssetCatalog(in: database)
        try createFileOperations(in: database)
        try createImportReceipts(in: database)
        try createSyncTables(in: database)
        try createRecoveryTables(in: database)
        try createIndexes(in: database)
    }

    private static func createMigrationTables(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE migration_runs (
                id TEXT NOT NULL PRIMARY KEY,
                sourceFingerprint TEXT NOT NULL,
                importerVersion TEXT NOT NULL,
                sourceModel TEXT,
                phase TEXT NOT NULL,
                status TEXT NOT NULL,
                metadataTotal INTEGER,
                metadataCompleted INTEGER NOT NULL DEFAULT 0,
                batchCursor BLOB,
                batchCount INTEGER NOT NULL DEFAULT 0,
                batchSHA256 TEXT,
                startedAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                errorMessage TEXT
            )
            """)

        try database.execute(sql: """
            CREATE TABLE migration_row_map (
                runID TEXT NOT NULL,
                sourceEntity TEXT NOT NULL,
                sourceObjectID TEXT NOT NULL,
                destinationStorageID TEXT,
                sourceURI TEXT,
                createdAt REAL NOT NULL,
                PRIMARY KEY (runID, sourceEntity, sourceObjectID),
                FOREIGN KEY (runID) REFERENCES migration_runs(id)
            )
            """)
    }

    private static func createAssetCatalog(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE asset_catalog (
                storageID TEXT NOT NULL PRIMARY KEY,
                sourceRoot TEXT,
                sourceRelativePath TEXT,
                destinationRoot TEXT,
                destinationRelativePath TEXT,
                kind TEXT NOT NULL,
                byteLength INTEGER,
                sha256 TEXT,
                state TEXT NOT NULL,
                isExternal INTEGER NOT NULL DEFAULT 0,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                CHECK (sourceRelativePath IS NULL OR (
                    sourceRoot IS NOT NULL AND
                    sourceRelativePath <> '' AND
                    substr(sourceRelativePath, 1, 1) <> '/' AND
                    sourceRelativePath NOT LIKE '../%' AND
                    sourceRelativePath NOT LIKE '%/../%' AND
                    sourceRelativePath NOT LIKE '%/..'
                )),
                CHECK (destinationRelativePath IS NULL OR (
                    destinationRoot IS NOT NULL AND
                    destinationRelativePath <> '' AND
                    substr(destinationRelativePath, 1, 1) <> '/' AND
                    destinationRelativePath NOT LIKE '../%' AND
                    destinationRelativePath NOT LIKE '%/../%' AND
                    destinationRelativePath NOT LIKE '%/..'
                ))
            )
            """)
    }

    private static func createFileOperations(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE file_operations (
                id TEXT NOT NULL PRIMARY KEY,
                assetID TEXT,
                operation TEXT NOT NULL,
                state TEXT NOT NULL,
                ownerStorageID TEXT,
                ownerRevision INTEGER,
                sourceRoot TEXT,
                sourceRelativePath TEXT,
                destinationRoot TEXT,
                destinationRelativePath TEXT,
                expectedByteLength INTEGER,
                expectedSHA256 TEXT,
                attemptCount INTEGER NOT NULL DEFAULT 0,
                lastError TEXT,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                FOREIGN KEY (assetID) REFERENCES asset_catalog(storageID) ON DELETE RESTRICT,
                CHECK (sourceRelativePath IS NULL OR (
                    sourceRoot IS NOT NULL AND
                    sourceRelativePath <> '' AND
                    substr(sourceRelativePath, 1, 1) <> '/' AND
                    sourceRelativePath NOT LIKE '../%' AND
                    sourceRelativePath NOT LIKE '%/../%' AND
                    sourceRelativePath NOT LIKE '%/..'
                )),
                CHECK (destinationRelativePath IS NULL OR (
                    destinationRoot IS NOT NULL AND
                    destinationRelativePath <> '' AND
                    substr(destinationRelativePath, 1, 1) <> '/' AND
                    destinationRelativePath NOT LIKE '../%' AND
                    destinationRelativePath NOT LIKE '%/../%' AND
                    destinationRelativePath NOT LIKE '%/..'
                ))
            )
            """)
    }

    private static func createImportReceipts(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE import_receipts (
                receiptID TEXT NOT NULL PRIMARY KEY,
                sourceTransferID TEXT NOT NULL UNIQUE,
                destinationStorageID TEXT,
                outcome TEXT NOT NULL,
                createdAt REAL NOT NULL
            )
            """)
    }

    private static func createSyncTables(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE sync_state (
                accountID TEXT NOT NULL,
                scope TEXT NOT NULL,
                stateKey TEXT NOT NULL,
                value BLOB,
                updatedAt REAL NOT NULL,
                PRIMARY KEY (accountID, scope, stateKey)
            )
            """)

        try database.execute(sql: """
            CREATE TABLE sync_outbox (
                id TEXT NOT NULL PRIMARY KEY,
                mutationType TEXT NOT NULL,
                payload BLOB,
                accountID TEXT NOT NULL,
                generationID TEXT NOT NULL,
                contentRevision INTEGER,
                state TEXT NOT NULL,
                requestedAt REAL,
                updatedAt REAL NOT NULL
            )
            """)
    }

    private static func createRecoveryTables(in database: Database) throws {
        try database.execute(sql: """
            CREATE TABLE recovery_items (
                id TEXT NOT NULL PRIMARY KEY,
                category TEXT NOT NULL,
                relativePath TEXT,
                payload BLOB,
                reason TEXT NOT NULL,
                provenance TEXT,
                createdAt REAL NOT NULL
            )
            """)

        try database.execute(sql: """
            CREATE TABLE content_revisions (
                id TEXT NOT NULL PRIMARY KEY,
                contentKind TEXT NOT NULL,
                contentStorageID TEXT NOT NULL,
                revision INTEGER NOT NULL,
                payload BLOB NOT NULL,
                capturedAt REAL NOT NULL,
                UNIQUE (contentKind, contentStorageID, revision)
            )
            """)
    }

    private static func createIndexes(in database: Database) throws {
        let indexSQL = [
            "CREATE INDEX recordings_by_source_id ON recordings (id)",
            "CREATE INDEX recordings_by_date ON recordings (recordingDate, storageID)",
            "CREATE INDEX transcripts_by_recording_storage_id ON transcripts (recordingStorageID)",
            "CREATE INDEX transcripts_by_recording_id ON transcripts (recordingId)",
            "CREATE INDEX summaries_by_recording_storage_id ON summaries (recordingStorageID)",
            "CREATE INDEX summaries_by_recording_id ON summaries (recordingId)",
            "CREATE INDEX summaries_by_transcript_storage_id ON summaries (transcriptStorageID)",
            "CREATE INDEX jobs_by_recording_storage_id ON processing_jobs (recordingStorageID)",
            "CREATE INDEX jobs_by_status ON processing_jobs (status, updatedAt)",
            "CREATE INDEX archive_locations_by_recording_id ON archive_locations (recordingId)",
            "CREATE INDEX migration_rows_by_source ON migration_row_map (sourceEntity, sourceObjectID)",
            "CREATE INDEX assets_by_state ON asset_catalog (state, updatedAt)",
            "CREATE INDEX outbox_by_eligibility ON sync_outbox (state, requestedAt)",
            "CREATE INDEX file_operations_by_state ON file_operations (state, updatedAt)"
        ]

        for sql in indexSQL {
            try database.execute(sql: sql)
        }
    }
}
