import XCTest
import CoreData
@testable import CloudKitSyncStatus

@available(iOS 14.0, *)
final class SyncStatusTests: XCTestCase {
    func testCanDetectImportError() {
        // Given an active network connection
        let syncStatus = SyncStatus(setupSuccessful: nil, importSuccessful: nil,
                                            exportSuccessful: nil, networkAvailable: true)

        // When NSPersistentCloudKitContainer reports an unsuccessful import
        let errorText = "I don't like clouds"
        let error = NSError(domain: errorText, code: 0, userInfo: nil)
        let event = SyncStatus.SyncEvent(type: .import, succeeded: false,
                                                 error: error)
        syncStatus.setProperties(from: event)

        // Then importError is true
        XCTAssertTrue(syncStatus.importError)

        // and importSuccessful is false
        XCTAssert(syncStatus.importSuccessful == false)

        // and the error's localized description is "I don't like clouds"
        XCTAssertEqual(syncStatus.lastImportError, error.localizedDescription)
    }

    func testCanDetectExportError() {
        // Given an active network connection
        let syncStatus = SyncStatus(setupSuccessful: nil, importSuccessful: nil,
                                            exportSuccessful: nil, networkAvailable: true)

        // When NSPersistentCloudKitContainer reports an unsuccessful import
        let errorText = "I don't like clouds"
        let error = NSError(domain: errorText, code: 0, userInfo: nil)
        let event = SyncStatus.SyncEvent(type: .export, succeeded: false,
                                                 error: error)
        syncStatus.setProperties(from: event)

        // Then exportError is true
        XCTAssertTrue(syncStatus.exportError)

        // and exportSuccessful is false
        XCTAssert(syncStatus.exportSuccessful == false)

        // and the error's localized description is "I don't like clouds"
        XCTAssertEqual(syncStatus.lastExportError, error.localizedDescription)
    }

    static var allTests = [
        ("testCanDetectImportError", testCanDetectImportError),
        ("testCanDetectExportError", testCanDetectExportError),
    ]
}
