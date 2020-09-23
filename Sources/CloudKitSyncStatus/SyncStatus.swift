//
//  SyncStatus.swift
//  Starfish
//
//  Created by Grant Grueninger on 9/17/20.
//  Copyright © 2020 Grant Grueninger. All rights reserved.
//

import Foundation
import CoreData
import Combine
import Network

/// The current status of iCloud sync as reported by `NSPersistentCloudKitContainer`
///
/// `SyncStatus` listens to the notifications sent out by `NSPersistentCloudKitContainer`
/// and translates them into a few published properties that can give your app a current state of its sync.
///
/// The primary use for this is to detect that rare condition in which CloudKit (and therefore your app) will just stop syncing with no warning and no notification
/// to the user. Well, now there's an immediate warning, and you can notify the user.
///
/// This SwiftUI view will display a red error image at the top of the screen if there's an import or export error:
///
///     import CloudKitSyncStatus
///     struct SyncStatusView: View {
///         @available(iOS 14.0, *)
///         @ObservedObject var syncStatus = SyncStatus.shared
///
///         var body: some View {
///             // Report only on real sync errors
///             if #available(iOS 14.0, *), (syncStatus.importError || syncStatus.exportError) {
///                 VStack {
///                     HStack {
///                         if syncStatus.importError {
///                             Image(systemName: "icloud.and.arrow.down").foregroundColor(.red)
///                         }
///                         if syncStatus.exportError {
///                             Image(systemName: "icloud.and.arrow.up").foregroundColor(.red)
///                         }
///                     }
///                     Spacer()
///                 }
///             }
///         }
///     }
///
/// `SyncStatus` has a few "magic" properties, which are featured in the example above, and are what you
/// really should use. Avoid the temptation to offer a continuous "sync status", and _absolutely_ avoid the temptation to detect when "sync is finished",
/// as in a distributed environment (such as the one `NSPersistentCloudKitContainer` is part of), sync is never "finished", and you're asking for
/// "bad things", "unpredictable results", etc if you attempt to detect "sync is finished".
///
/// Anyway, the "magic" properties are:
/// - `syncError`, which tells you that something has gone wrong when nothing should be going wrong (i.e., there's an active network connection)
/// - `importError`, which tells you that the last import failed when it shouldn't have (i.e., there's an active network connection)
/// - `exportError`, which tells you that the last export failed when it shouldn't have (i.e., there's an active network connection)
///
/// Detecting these conditions is important because the usual "fix" for CloudKit not syncing is to delete the local database. This is fine if your import
/// stopped working, but if the export stopped working, it means that your user will lose any changes they made between the time the sync failed and
/// when the user noticed the failure. Previously, that time was based on when the user looked at two devices and noticed that they didn't contain the same data.
/// With `SyncStatus`, your app can report (or act on) that failure _immediately_, saving your user's data and your app's reputation.
@available(iOS 14.0, macCatalyst 14.0, macOS 11.0, *)
class SyncStatus: ObservableObject {
    /// A singleton to use
    static let shared = SyncStatus()

    /// Status of NSPersistentCloudKitContainer setup.
    ///
    /// This is `nil` if NSPersistentCloudKitContainer hasn't sent a notification about a event of type `setup`, `true` if the last notification
    /// of an event of type `setup` succeeded, and `false` if the last notification of an event of type `setup` failed.
    @Published var setupSuccessful: Bool? = nil

    /// Status of last NSPersistentCloudKitContainer import.
    ///
    /// This is `nil` if NSPersistentCloudKitContainer hasn't sent a notification about a event of type `import`, `true` if the last notification
    /// of an event of type `import` succeeded, and `false` if the last notification of an event of type `import` failed.
    /// On failure, the `lastImportError` property will contain the localized description of
    @Published var importSuccessful: Bool? = nil

    /// The localized description of the last import error, or `nil` if the last import succeeded (or no import has yet been run)
    var lastImportError: String? = nil

    /// Status of last NSPersistentCloudKitContainer export.
    ///
    /// This is `nil` if NSPersistentCloudKitContainer hasn't sent a notification about a event of type `export`, `true` if the last notification
    /// of an event of type `export` succeeded, and `false` if the last notification of an event of type `export` failed.
    /// On failure, the `lastExportError` property will contain the localized description of
    @Published var exportSuccessful: Bool? = nil

    /// The localized description of the last import error, or `nil` if the last import succeeded (or no import has yet been run)
    var lastExportError: String? = nil

    /// Is the network available, as defined
    @Published var networkAvailable: Bool? = nil

    /// Is iCloud import sync broken?
    ///
    /// Returns true if the network is available, NSPersistentCloudKitContainer ran an import, and the import reported an error
    var importError: Bool {
        return networkAvailable == true && importSuccessful == false
    }

    /// Is iCloud export sync broken?
    ///
    /// Returns true if the network is available, NSPersistentCloudKitContainer ran an export, and the export reported an error
    var exportError: Bool {
        return networkAvailable == true && exportSuccessful == false
    }

    /// Is iCloud sync broken?
    ///
    /// Returns true if the network is available and the last attempted sync (import or export) didn't succeed.
    /// If this is true, your app likely needs to take some action to fix sync, e.g. clearing the local cache, quitting/restarting, etc.
    /// See importError or exportError for the error.
    var syncError: Bool {
        return importError || exportError
    }

    /// Where we store Combine cancellables for publishers we're listening to, e.g. NSPersistentCloudKitContainer's notifications.
    fileprivate var disposables = Set<AnyCancellable>()

    /// Network path monitor that's used to track whether we can reach the network at all
    //    fileprivate let monitor: NetworkMonitor = NWPathMonitor()
    fileprivate let monitor = NWPathMonitor()

    /// The queue on which we'll run our network monitor
    fileprivate let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    /// Creates a SyncStatus with values set manually and doesn't listen for NSPersistentCloudKitContainer notifications (for testing/previews)
    init(setupSuccessful: Bool? = nil, importSuccessful: Bool? = nil, exportSuccessful: Bool? = nil,
         networkAvailable: Bool? = nil) {
        self.setupSuccessful = setupSuccessful
        self.importSuccessful = importSuccessful
        self.exportSuccessful = exportSuccessful
        self.networkAvailable = networkAvailable
    }

    init() {
        // XCode 12 is reporting that "eventChangedNotification" doesn't exist when compiling on Mac even with the
        // @available set for the class. Temporary hack to let it compile on Mac.
        // Fixed in Xcode 12.2 beta, but I'm leaving this commented out in case I need to add it back to do a release.
        //        #if !targetEnvironment(macCatalyst)
        NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .debounce(for: 1, scheduler: DispatchQueue.main)
            .sink(receiveValue: { notification in
                if let cloudEvent = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event {
                    // This translation to our "SyncEvent" lets us write unit tests, since
                    // NSPersistentCloudKitContainer.Event's properties are read-only (meaning we can't fire off a
                    // fake one).
                    let event = SyncEvent(from: cloudEvent)
                    self.setProperties(from: event)
                }
            })
            .store(in: &disposables)
        //        #endif

        // Update the network status when the OS reports a change. Note that we ignore whether the connection is
        // expensive or not - we just care whether iCloud is _able_ to sync. If there's no network,
        // NSPersistentCloudKitContainer will try to sync but report an error. We consider that a real error unless
        // the network is not available at all. If it's available but expensive, it's still an error.
        // Obstensively, if the user's device has iCloud syncing turned off (e.g. due to low power mode or not
        // allowing syncing over cellular connections), NSPersistentCloudKitContainer won't try to sync.
        // If that assumption is incorrect, we'll need to update the logic in this class.
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async { self.networkAvailable = (path.status == .satisfied) }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        // Clean up our listeners, just to be neat
        monitor.cancel()
        for cancellable in disposables {
            cancellable.cancel()
        }

    }

    /// Sets the status properties based on the information in the provided sync event
    func setProperties(from event: SyncEvent) {
        switch event.type {
        case .import:
            self.importSuccessful = event.succeeded
            self.lastImportError = event.error?.localizedDescription
        case .setup:
            self.setupSuccessful = event.succeeded
        case .export:
            self.exportSuccessful = event.succeeded
            self.lastExportError = event.error?.localizedDescription
        @unknown default:
            assertionFailure("New event type added to NSPersistenCloudKitContainer")
        }
    }

    /// A sync event containing the values from NSPersistentCloudKitContainer.Event that we track
    struct SyncEvent {
        var type: NSPersistentCloudKitContainer.EventType
        var succeeded: Bool
        var error: Error?

        /// Creates a SyncEvent from explicitly provided values (for testing)
        init(type: NSPersistentCloudKitContainer.EventType, succeeded: Bool, error: Error) {
            self.type = type
            self.succeeded = succeeded
            self.error = error
        }

        /// Creates a SyncEvent from an NSPersistentCloudKitContainer Event
        init(from cloudKitEvent: NSPersistentCloudKitContainer.Event) {
            self.type = cloudKitEvent.type
            self.succeeded = cloudKitEvent.succeeded
            self.error = cloudKitEvent.error
        }
    }
}
