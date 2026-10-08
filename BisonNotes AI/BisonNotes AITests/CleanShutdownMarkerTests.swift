import XCTest
@testable import BisonNotes_AI

/// Each test plays a sequence of process lifetimes against one defaults suite:
/// `consumeLaunch` starts a process, `arm` is the session becoming active, and
/// `markClean` is it entering the background or terminating. A process that ends
/// without `markClean` was killed — by a crash, or by iOS reclaiming a suspended app.
final class CleanShutdownMarkerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CleanShutdownMarkerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstInstallIsClean() {
        XCTAssertFalse(CleanShutdownMarker.consumeLaunch(in: defaults))
    }

    /// The field report: iOS launched the app in the background to deliver a Watch
    /// recording, then killed it while suspended. Nothing ever became active, so
    /// the next launch must not report a crash.
    func testBackgroundLaunchKilledWhileSuspendedIsNotACrash() {
        _ = CleanShutdownMarker.consumeLaunch(in: defaults)

        XCTAssertFalse(CleanShutdownMarker.consumeLaunch(in: defaults))
    }

    func testRepeatedBackgroundLaunchesNeverReportACrash() {
        for _ in 0..<5 {
            XCTAssertFalse(CleanShutdownMarker.consumeLaunch(in: defaults))
        }
    }

    func testActiveSessionKilledWithoutBackgroundingIsACrash() {
        _ = CleanShutdownMarker.consumeLaunch(in: defaults)
        CleanShutdownMarker.arm(in: defaults)

        XCTAssertTrue(CleanShutdownMarker.consumeLaunch(in: defaults))
    }

    func testActiveSessionThatBackgroundsIsClean() {
        _ = CleanShutdownMarker.consumeLaunch(in: defaults)
        CleanShutdownMarker.arm(in: defaults)
        CleanShutdownMarker.markClean(in: defaults)

        XCTAssertFalse(CleanShutdownMarker.consumeLaunch(in: defaults))
    }

    /// Returning to the foreground re-arms, so a crash after a clean background
    /// transition in the same process is still caught.
    func testCrashAfterReturningToForegroundIsACrash() {
        _ = CleanShutdownMarker.consumeLaunch(in: defaults)
        CleanShutdownMarker.arm(in: defaults)
        CleanShutdownMarker.markClean(in: defaults)
        CleanShutdownMarker.arm(in: defaults)

        XCTAssertTrue(CleanShutdownMarker.consumeLaunch(in: defaults))
    }

    /// A real crash is reported once. A background launch that follows it must not
    /// report the same crash again on the launch after.
    func testCrashIsReportedOnlyOnce() {
        _ = CleanShutdownMarker.consumeLaunch(in: defaults)
        CleanShutdownMarker.arm(in: defaults)

        XCTAssertTrue(CleanShutdownMarker.consumeLaunch(in: defaults))
        XCTAssertFalse(CleanShutdownMarker.consumeLaunch(in: defaults))
    }

    /// Devices upgrading from v2.5 carry the old marker, written as `false` at every
    /// launch. The first launch after the upgrade still reads that one stale value;
    /// after that the new rules apply.
    func testStaleArmedMarkerFromPreviousVersionClearsAfterOneLaunch() {
        defaults.set(false, forKey: CleanShutdownMarker.key)

        XCTAssertTrue(CleanShutdownMarker.consumeLaunch(in: defaults))
        XCTAssertFalse(CleanShutdownMarker.consumeLaunch(in: defaults))
    }
}
