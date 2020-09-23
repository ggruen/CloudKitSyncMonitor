import XCTest

import CloudKitSyncStatusTests

var tests = [XCTestCaseEntry]()
tests += SyncStatusTests.allTests()
XCTMain(tests)
