import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMaintenanceGateRuntimeTests: XCTestCase {
    func testExclusiveAccessWaitsForNormalLeasesAndBlocksLaterNormalLeases() async throws {
        let gate = LibraryMaintenanceGate()
        let firstNormal = try await gate.acquireNormal()

        let exclusiveTask = Task {
            try await gate.acquireExclusive()
        }
        for _ in 0..<100 where await gate.status().waitingExclusiveCount != 1 {
            await Task.yield()
        }
        let exclusiveWaitingStatus = await gate.status()
        XCTAssertEqual(exclusiveWaitingStatus.waitingExclusiveCount, 1)

        let laterNormalTask = Task {
            try await gate.acquireNormal()
        }
        for _ in 0..<100 where await gate.status().waitingNormalCount != 1 {
            await Task.yield()
        }
        let normalWaitingStatus = await gate.status()
        XCTAssertEqual(normalWaitingStatus.waitingNormalCount, 1)

        await firstNormal.release()
        let exclusive = try await exclusiveTask.value
        let maintenanceStatus = await gate.status()
        XCTAssertEqual(maintenanceStatus.maintenanceActive, true)

        await exclusive.release()
        let laterNormal = try await laterNormalTask.value
        let laterNormalStatus = await gate.status()
        XCTAssertEqual(laterNormalStatus.activeNormalCount, 1)
        await laterNormal.release()
        let finalStatus = await gate.status()
        XCTAssertEqual(finalStatus, LibraryMaintenanceGate.Status(
            activeNormalCount: 0,
            waitingNormalCount: 0,
            waitingExclusiveCount: 0,
            maintenanceActive: false
        ))
    }

    func testCancelledExclusiveWaiterIsRemovedAndDoesNotBlockNormalAccess() async throws {
        let gate = LibraryMaintenanceGate()
        let firstNormal = try await gate.acquireNormal()

        let exclusiveTask = Task {
            try await gate.acquireExclusive()
        }
        for _ in 0..<100 where await gate.status().waitingExclusiveCount != 1 {
            await Task.yield()
        }
        let waitingStatus = await gate.status()
        XCTAssertEqual(waitingStatus.waitingExclusiveCount, 1)

        exclusiveTask.cancel()
        _ = try? await exclusiveTask.value
        for _ in 0..<100 where await gate.status().waitingExclusiveCount != 0 {
            await Task.yield()
        }
        let cancelledStatus = await gate.status()
        XCTAssertEqual(cancelledStatus.waitingExclusiveCount, 0)

        let secondNormal = try await gate.acquireNormal()
        let normalStatus = await gate.status()
        XCTAssertEqual(normalStatus.activeNormalCount, 2)
        await secondNormal.release()
        await firstNormal.release()
    }

    func testLeaseReleaseIsIdempotentAndCancelledMaintenanceReleasesGate() async throws {
        let lease = try await LibraryMaintenanceGate().acquireExclusive()
        await lease.release()
        await lease.release()

        let gate = LibraryMaintenanceGate()
        let maintenanceTask = Task<Bool, Error> {
            try await gate.withExclusiveMaintenance {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return true
            }
        }
        for _ in 0..<100 where await gate.status().maintenanceActive == false {
            await Task.yield()
        }
        let activeStatus = await gate.status()
        XCTAssertEqual(activeStatus.maintenanceActive, true)

        maintenanceTask.cancel()
        _ = try? await maintenanceTask.value
        for _ in 0..<100 where await gate.status().maintenanceActive {
            await Task.yield()
        }
        let releasedStatus = await gate.status()
        XCTAssertEqual(releasedStatus.maintenanceActive, false)

        let normal = try await gate.acquireNormal()
        await normal.release()
    }
}
