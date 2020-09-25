import XCTest

import CloudKitSyncMonitorTests

var tests = [XCTestCaseEntry]()
tests += SyncStatusTests.allTests()
tests += SyncMonitorTests.allTests()
XCTMain(tests)
