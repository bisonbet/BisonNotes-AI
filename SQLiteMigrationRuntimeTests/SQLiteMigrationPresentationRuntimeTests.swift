import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMigrationPresentationRuntimeTests: XCTestCase {
    func testPresentationStateShowsOnlyDurableProgressAndCompletes() {
        var model = SQLiteMigrationPresentationModel()
        model.start()
        XCTAssertEqual(model.state, .running)

        model.apply(
            SQLiteMigrationProgress(
                phase: .importingMetadata,
                runID: "run-1",
                metadataCompleted: 2,
                metadataTotal: 4,
                batchCount: 1,
                importedRowCount: 2,
                skippedRowCount: 0,
                settingsCompleted: 0,
                settingsTotal: 0
            )
        )
        XCTAssertEqual(model.progress?.metadataCompleted, 2)
        XCTAssertEqual(model.state, .running)
        XCTAssertNil(model.failureMessage)

        model.apply(
            SQLiteMigrationProgress(
                phase: .completed,
                runID: "run-1",
                metadataCompleted: 4,
                metadataTotal: 4,
                batchCount: 2,
                importedRowCount: 4,
                skippedRowCount: 0,
                settingsCompleted: 1,
                settingsTotal: 1
            )
        )
        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(model.progress?.fractionCompleted, 1)
    }

    func testCancellationAndRetryRemainResumable() {
        var model = SQLiteMigrationPresentationModel()
        model.start()
        model.apply(
            SQLiteMigrationProgress(
                phase: .importingMetadata,
                runID: "run-1",
                metadataCompleted: 3,
                metadataTotal: 8,
                batchCount: 1,
                importedRowCount: 3,
                skippedRowCount: 0,
                settingsCompleted: 0,
                settingsTotal: 2
            )
        )

        model.pause()
        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(model.progress?.phase, .paused)
        XCTAssertTrue(model.canStart)

        model.retry()
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.failureMessage)
        XCTAssertTrue(model.canStart)
    }

    func testFailureIsGenericAndRetryable() {
        var model = SQLiteMigrationPresentationModel()
        model.start()
        model.fail()

        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(
            model.failureMessage,
            SQLiteMigrationPresentationModel.genericFailureMessage
        )
        XCTAssertTrue(model.canStart)
    }

    func testCompletedStateCannotBeReopenedByStaleProgress() {
        var model = SQLiteMigrationPresentationModel()
        model.start()
        model.apply(
            SQLiteMigrationProgress(
                phase: .completed,
                runID: "run-1",
                metadataCompleted: 1,
                metadataTotal: 1,
                batchCount: 1,
                importedRowCount: 1,
                skippedRowCount: 0,
                settingsCompleted: 0,
                settingsTotal: 0
            )
        )

        model.apply(
            SQLiteMigrationProgress(
                phase: .importingMetadata,
                runID: "run-1",
                metadataCompleted: 0,
                metadataTotal: 1,
                batchCount: 0,
                importedRowCount: 0,
                skippedRowCount: 0,
                settingsCompleted: 0,
                settingsTotal: 0
            )
        )
        XCTAssertEqual(model.state, .completed)
        XCTAssertEqual(model.progress?.metadataCompleted, 1)
    }
}
