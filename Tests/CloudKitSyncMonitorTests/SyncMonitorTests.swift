//
//  SyncMonitorTests.swift
//  
//
//  Created by Grant Grueninger on 9/23/20.
//

import Foundation

import XCTest
import CoreData
@testable import CloudKitSyncMonitor

@available(iOS 15.0, macCatalyst 14.0, OSX 11, tvOS 15.0, *)
final class SyncMonitorTests: XCTestCase {
    func testCanDetectImportError() {
        // Given an active network connection
        let syncStatus: SyncMonitor = SyncMonitor(networkAvailable: true, listen: false)

        // When NSPersistentCloudKitContainer reports an unsuccessful import
        let errorText = "I don't like clouds"
        let error = NSError(domain: errorText, code: 0, userInfo: nil)
        let event = SyncMonitor.SyncEvent(type: .import, startDate: Date(), endDate: Date(), succeeded: false,
                                          error: error)
        syncStatus.setProperties(from: event)

        // Then importError's description is "I don't like clouds"
        XCTAssertEqual(syncStatus.importError?.localizedDescription, error.localizedDescription)

        // and importState failed
        if case .failed = syncStatus.importState {
            XCTAssert(true)
        } else {
            XCTAssert(false, "importState should be .failed")
        }
    }

    func testCanDetectExportError() {
        // Given an active network connection
        let syncStatus = SyncMonitor(networkAvailable: true, listen: false)

        // When NSPersistentCloudKitContainer reports an unsuccessful import
        let errorText = "I don't like clouds"
        let error = NSError(domain: errorText, code: 0, userInfo: nil)
        let event = SyncMonitor.SyncEvent(type: .export, startDate: Date(), endDate: Date(), succeeded: false,
                                          error: error)
        syncStatus.setProperties(from: event)

        // Then exportError's description is "I don't like clouds"
        XCTAssertEqual(syncStatus.exportError?.localizedDescription, error.localizedDescription)

        // and exportState failed
        if case .failed = syncStatus.exportState {
            XCTAssert(true)
        } else {
            XCTAssert(false, "exportState should be .failed")
        }
    }

    func testCanDetectImportSuccess() {
        // Given an active network connection
        let syncStatus: SyncMonitor = SyncMonitor(networkAvailable: true, listen: false)

        // When NSPersistentCloudKitContainer reports a successful import
        let event = SyncMonitor.SyncEvent(type: .import, startDate: Date(), endDate: Date(), succeeded: true,
                                          error: nil)
        syncStatus.setProperties(from: event)

        // Then importError is nil
        XCTAssert(syncStatus.importError == nil)

        // and importState is .succeeded
        if case .succeeded = syncStatus.importState {
            XCTAssert(true)
        } else {
            XCTAssert(false, "importState should be .succeeded")
        }
    }

    func testCanDetectExportSuccess() {
        // Given an active network connection
        let syncStatus: SyncMonitor = SyncMonitor(networkAvailable: true, listen: false)

        // When NSPersistentCloudKitContainer reports a successful export
        let event = SyncMonitor.SyncEvent(type: .export, startDate: Date(), endDate: Date(), succeeded: true,
                                          error: nil)
        syncStatus.setProperties(from: event)

        // Then exportError is nil
        XCTAssert(syncStatus.exportError == nil)

        // and exportState is .succeeded
        if case .succeeded = syncStatus.exportState {
            XCTAssert(true)
        } else {
            XCTAssert(false, "exportState should be .succeeded")
        }
    }

    func testSetsStatusToInProgressWhenEventHasNoEndDate() {
        // Given an active network connection
        let syncStatus: SyncMonitor = SyncMonitor(networkAvailable: true, listen: false)

        // When NSPersistentCloudKitContainer reports an event with a start date but no end date
        let event = SyncMonitor.SyncEvent(type: .export, startDate: Date(), endDate: nil, succeeded: false,
                                          error: nil)
        syncStatus.setProperties(from: event)

        // Then exportError is nil
        XCTAssert(syncStatus.exportError == nil)

        // and exportState is .inProgress
        if case .inProgress = syncStatus.exportState {
            XCTAssert(true)
        } else {
            XCTAssert(false, "exportState should be .inProgress")
        }
    }

    func testSetsStatusToNotStartedOnStartup() {
        // Given an active network connection
        let syncStatus: SyncMonitor = SyncMonitor(networkAvailable: true, listen: false)

        // When we check status before an event has been reported
        let status = syncStatus.importState

        // Then the status is ".notStarted"
        if case .notStarted = status {
            XCTAssert(true)
        } else {
            XCTAssert(false, "importState should be .notStarted")
        }
    }

    static var allTests = [
        ("testCanDetectImportError", testCanDetectImportError),
        ("testCanDetectExportError", testCanDetectExportError),
        ("testCanDetectImportSuccess", testCanDetectImportSuccess),
        ("testCanDetectExportSuccess", testCanDetectExportSuccess),
        ("testSetsStatusToInProgressWhenEventHasNoEndDate", testSetsStatusToInProgressWhenEventHasNoEndDate),
        ("testSetsStatusToNotStartedOnStartup", testSetsStatusToNotStartedOnStartup),
    ]
}
