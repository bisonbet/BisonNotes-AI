import Foundation
import XCTest
@testable import BisonNotes_AI

final class RestoredAudioFileInstallerTests: XCTestCase {
    func testSuccessfulCopyReplacesExistingAudioAndLeavesNoStagingFile() throws {
        try withFiles { root, source, destination in
            try RestoredAudioFileInstaller.install(from: source, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), Data("new audio".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["local", "source"])
        }
    }

    func testMissingAssetPreservesExistingAudio() throws {
        try withFiles { root, source, destination in
            try FileManager.default.removeItem(at: source)
            XCTAssertThrowsError(try RestoredAudioFileInstaller.install(from: source, to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), Data("valid local audio".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["local"])
        }
    }

    func testPartialCopyFailurePreservesExistingAudioAndRemovesStaging() throws {
        try withFiles { root, source, destination in
            XCTAssertThrowsError(try RestoredAudioFileInstaller.install(
                from: source, to: destination, fileManager: FailingRestoreCopyFileManager()
            ))
            XCTAssertEqual(try Data(contentsOf: destination), Data("valid local audio".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["local", "source"])
        }
    }

    func testNewDestinationCanBeInstalled() throws {
        try withFiles { _, source, destination in
            try FileManager.default.removeItem(at: destination)
            try RestoredAudioFileInstaller.install(from: source, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), Data("new audio".utf8))
        }
    }

    func testFailedRenamePreservesDestinationAndRemovesStaging() throws {
        try withFiles { root, source, destination in
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let child = destination.appendingPathComponent("keep")
            try Data("keep".utf8).write(to: child)
            XCTAssertThrowsError(try RestoredAudioFileInstaller.install(from: source, to: destination))
            XCTAssertEqual(try Data(contentsOf: child), Data("keep".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["local", "source"])
        }
    }

    private func withFiles(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("local")
        try Data("new audio".utf8).write(to: source)
        try Data("valid local audio".utf8).write(to: destination)
        try body(root, source, destination)
    }
}

private final class FailingRestoreCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        try Data("partial".utf8).write(to: destination)
        throw POSIXError(.ENOSPC)
    }
}
