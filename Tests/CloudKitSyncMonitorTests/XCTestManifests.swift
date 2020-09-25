import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(SyncMonitorTests.allTests),
    ]
}
#endif
