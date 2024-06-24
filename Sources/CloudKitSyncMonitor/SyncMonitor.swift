//
//  SyncMonitor.swift
//  
//
//  Created by Grant Grueninger on 9/23/20.
//

import Combine
import CoreData
import Network
import SwiftUI
import CloudKit

/// An object, usually used as a singleton, that provides, and publishes, the current state of `NSPersistentCloudKitContainer`'s sync
///
/// This class is overkill when it comes to reporting on iCloud sync. Normally, `NSPersistentCloudKitContainer` will sync happily and you can
/// leave it alone. Every once in a while, however, it will hit an error that makes it stop syncing. This is what you really want to detect, because, since iCloud
/// is the "source of truth" for your `NSPersistentCloudKitContainer` data, a sync failure can mean data loss.
///
/// Here are the basics:
///
///     // If true, either setupError, importError or exportError will contain an error
///     if SyncMonitor.shared.syncError {
///         if let e = SyncMonitor.shared.setupError {
///             print("Unable to set up iCloud sync, changes won't be saved! \(e.localizedDescription)")
///         }
///         if let e = SyncMonitor.shared.importError {
///             print("Import is broken: \(e.localizedDescription)")
///         }
///         if let e = SyncMonitor.shared.exportError {
///             print("Export is broken - your changes aren't being saved! \(e.localizedDescription)")
///         }
///     } else if SyncMonitor.shared.notSyncing {
///         print("Sync should be working, but isn't. Look for a badge on Settings or other possible issues.")
///     }
///
/// `syncError` and `notSyncing`, together, tell you if there's a problem that `NSPersistentCloudKitContainer` has announced or not announced
/// (respectively).
/// The `setupError`, `importError`, and `exportError` properties can give you the reported error. Digging deeper, `setupState`, `importState`,
/// and `exportState` give you the state of each type of `NSPersistentCloudKitContainer` event in a nice little `SyncState` enum with associated
/// values that let you get even more granular, e.g. to find whether each type of event is in progress, succeeded, or failed,  the start and end time of the event, and
/// any error reported if the event failed.
///
/// *Some example code to use in SwiftUI views*
///
/// First, observe the shared syncmonitor instance so your view will update if the state changes:
///
///     @ObservedObject var syncMonitor: SyncMonitor = SyncMonitor.shared
///
/// Show a sync status icon:
///
///     Image(systemName: syncMonitor.syncStateSummary.symbolName)
///         .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
///
/// Only show an icon if there's a sync error:
///
///     if syncMonitor.syncStateSummary.isBroken {
///         Image(systemName: syncMonitor.syncStateSummary.symbolName)
///             .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
///     }
///
/// Only show an icon when syncing is happening:
///
///     // See http://goshdarnifcaseletsyntax.com for "if case" help. :)
///     if case .inProgress = syncMonitor.syncStateSummary {
///         Image(systemName: syncMonitor.syncStateSummary.symbolName)
///             .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
///     }
///
/// Show a detailed error reporting graphic - shows which type(s) of events are failing.
///
///     Group {
///         if syncMonitor.syncError {
///             VStack {
///                 HStack {
///                     if syncMonitor.setupError != nil {
///                         Image(systemName: "xmark.icloud").foregroundColor(.red)
///                     }
///                     if syncMonitor.importError != nil {
///                         Image(systemName: "icloud.and.arrow.down").foregroundColor(.red)
///                     }
///                     if syncMonitor.exportError != nil {
///                         Image(systemName: "icloud.and.arrow.up").foregroundColor(.red)
///                     }
///                 }
///             }
///         } else if syncMonitor.notSyncing {
///             Image(systemName: "xmark.icloud")
///         } else {
///             Image(systemName: "icloud").foregroundColor(.green)
///         }
///     }
///
@available(iOS 15.0, macCatalyst 15.0, OSX 12, tvOS 15.0, watchOS 8, *)
public class SyncMonitor: ObservableObject {
    /// A singleton to use
    public static let shared = SyncMonitor()

    // MARK: - Summary properties -

    /// Returns an overview of the state of sync, which you could use to display a summary icon
    ///
    /// The general sync state is detmined as follows:
    /// - If the network isn't available, the state summary is `.noNetwork`.
    /// - Otherwise, if the iCloud account isn't available (e.g. they're not logged in or have disabled iCloud for the app in Settings or System Preferences), the
    ///     state summary is`.accountNotAvailable`.
    /// - Otherwise, if `NSPersistentCloudKitContainer` reported an error for any event type the last time that event type ran, the state summary is
    ///     `.error`.
    /// - Otherwise, if `notSyncing` is true, the state is `.notSyncing`.
    /// - Otherwise, if all event types are `.notStarted`, the state is `.notStarted`.
    /// - Otherwise, if any event type is `.inProgress`, the state is `.inProgress`.
    /// - Otherwise, if all event types are `.successful`, the state is `.succeeded`.
    /// - Otherwise, the state is `.unknown`.
    ///
    /// Here's how you might use this in a SwiftUI view:
    ///
    ///     @ObservedObject var syncMonitor: SyncMonitor = SyncMonitor.shared
    ///
    ///     Image(systemName: syncMonitor.syncStateSummary.symbolName)
    ///         .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
    ///
    /// Or maybe you only want to show errors:
    ///
    ///     if syncMonitor.syncStateSummary.isBroken {
    ///         Image(systemName: syncMonitor.syncStateSummary.symbolName)
    ///             .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
    ///     }
    ///
    /// Or, only show an icon when syncing is happening:
    ///
    ///     // See http://goshdarnifcaseletsyntax.com for "if case" help. :)
    ///     if case .inProgress = syncMonitor.syncStateSummary {
    ///         Image(systemName: syncMonitor.syncStateSummary.symbolName)
    ///             .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
    ///     }
    ///
    public var syncStateSummary: SyncSummaryStatus {
        if networkAvailable == false { return .noNetwork }
        guard case .available = iCloudAccountStatus else { return .accountNotAvailable }
        if syncError { return .error }
        if notSyncing { return .notSyncing }
        if case .notStarted = importState, case .notStarted = exportState, case .notStarted = setupState {
            return .notStarted
        }

        if case .inProgress = setupState { return .inProgress }
        if case .inProgress = importState { return .inProgress }
        if case .inProgress = exportState { return .inProgress }

        if case .succeeded = importState, case .succeeded = exportState {
            return .succeeded
        }
        return .unknown
    }

    /// Possible values for the summary of the state of iCloud sync
    public enum SyncSummaryStatus {
        case noNetwork, accountNotAvailable, error, notSyncing, notStarted, inProgress, succeeded, unknown

        /// A symbol you could use to display the status
        public var symbolName: String {
            switch self {
            case .noNetwork:
                return "bolt.horizontal.icloud"
            case .accountNotAvailable:
                return "lock.icloud"
            case .error:
                return "exclamationmark.icloud"
            case .notSyncing:
                return "xmark.icloud"
            case .notStarted:
                return "bolt.horizontal.icloud"
            case .inProgress:
                return "arrow.clockwise.icloud"
            case .succeeded:
                return "icloud"
            case .unknown:
                return "icloud.slash"
            }
        }
        
        // A string you could use to display the status
        public var description: String {
            switch self {
            case .noNetwork:
                return String(localized: "No network available")
            case .accountNotAvailable:
                return String(localized: "No iCloud account")
            case .error:
                return String(localized: "Error")
            case .notSyncing:
                return String(localized: "Not syncing to iCloud")
            case .notStarted:
                return String(localized: "Sync not started")
            case .inProgress:
                return String(localized: "Syncing...")
            case .succeeded:
                return String(localized: "Synced with iCloud")
            case .unknown:
                return String(localized: "Error")
            }
        }

        /// A color you could use for the symbol
        public var symbolColor: Color {
            switch self {
            case .noNetwork:
                return .gray
            case .accountNotAvailable:
                return .gray
            case .error:
                return .red
            case .notSyncing:
                return .red
            case .notStarted:
                return .gray
            case .inProgress:
                return .gray
            case .succeeded:
                return .green
            case .unknown:
                return .red
            }
        }

        /// Returns true if the state indicates that sync is broken
        public var isBroken: Bool {
            switch self {
            case .noNetwork:
                return false
            case .accountNotAvailable:
                return false
            case .error:
                return true
            case .notSyncing:
                return true
            case .notStarted:
                return false
            case .inProgress:
                return false
            case .succeeded:
                return false
            case .unknown:
                return true
            }
        }

        /// Convenience accessor that returns true if a sync is in progress
        ///
        /// This lets you do things like `if SyncMonitor.shared.broken || SyncMonitor.shared.inProgress { ... }`,
        /// since Swift doesn't like `case` statements intermixed into if statements.
        public var inProgress: Bool {
            if case .inProgress = self {
                return true
            }
            return false
        }
    }

    /// Returns true if `NSPersistentCloudKitContainer` has reported an error.
    ///
    /// This is a convenience property that returns true if `setupError`, `importError` or `exportError` is not nil.
    /// If `syncError` is true, then either `setupError`, `importError` or `exportError` (or any combination of them)) will contain an error object.
    ///
    ///     // If true, either setupError, importError or exportError will contain an error
    ///     if SyncMonitor.shared.syncError {
    ///         if let e = SyncMonitor.shared.setupError {
    ///             print("Unable to set up iCloud sync, changes won't be saved! \(e.localizedDescription)")
    ///         }
    ///         if let e = SyncMonitor.shared.importError {
    ///             print("Import is broken: \(e.localizedDescription)")
    ///         }
    ///         if let e = SyncMonitor.shared.exportError {
    ///             print("Export is broken - your changes aren't being saved! \(e.localizedDescription)")
    ///         }
    ///     }
    ///
    /// `syncError` being `true` means that `NSPersistentCloudKitContainer` sent a notification that included an error.
    public var syncError: Bool {
        return setupError != nil || importError != nil || exportError != nil
    }

    /// Returns `true` if there's no reason that we know of why sync shouldn't be working
    ///
    /// That is, the user's iCloud account status is "available", the network is available, there are no recorded sync errors, and setup is complete and succeeded.
    public var shouldBeSyncing: Bool {
        if case .available = iCloudAccountStatus, self.networkAvailable == true, !syncError,
           case .succeeded = setupState {
            return true
        }
        return false
    }

    /// Detects a condition in which CloudKit _should_ be syncing, but isn't.
    ///
    /// `notSyncing` is true if `shouldBeSyncing` is true (see `shouldBeSyncing`) but `importState` is still `.notStarted`.
    ///
    /// The first thing `NSPersistentCloudKitContainer`does when the app starts is to set up, then run an import. So, `notSyncing` should be true for
    /// a very very short period of time (e.g. less than a second) for the time between when setup completes and the import starts. As such, it's suitable for
    /// displaying an error graphic to the user, e.g. `Image(systemName: "xmark.icloud")` if `notSyncing` is `true`, but not necessarily for
    /// programmatic action (unless notSyncing stays true for more than a few seconds).
    ///
    ///     if SyncMonitor.shared.syncError {
    ///         // Act on error
    ///     } else if SyncMonitor.shared.notSyncing {
    ///         print("Sync should be working, but isn't. Look for a badge on Settings or other possible issues.")
    ///     }
    ///
    /// I would argue that `notSyncing` being `true` for a longer period of time indicates a bug in `NSPersistentCloudKitContainer`. E.g. the case
    /// that made me write this computed property is that if Settings on iOS wants the user to log in again, CloudKit will report a "partial error" when setting up,
    /// but ultimately send a notifiation stating that setup was successful; however, CloudKit will then just not sync, providing no errors. `notSyncing` detects
    /// this condition, and those like it. If you see `notSyncing` being triggered, I'd recommend isolating the issue (e.g. the one above) and filing a FB about it
    /// to Apple.
    public var notSyncing: Bool {
        if case .notStarted = importState, shouldBeSyncing {
            return true
        }
        return false
    }

    /// If not `nil`, there is a real problem encountered when CloudKit was trying to set itself up
    ///
    /// This means `NSPersistentCloudKitContainer` probably won't try to do imports or exports, which means that data won't be synced. However, it's
    /// usually caused by something that can be fixed without deleting the DB, so it usually means that sync will just be delayed, unlike exportError, which
    /// usually requires deleting the local DB, thus losing changes.
    ///
    /// You should examime the error for the cause. You may then be able to at least report it to the user, if not automate a "fix" in your app.
    public var setupError: Error? {
        if networkAvailable == true, let error = setupState.error {
            return error
        }
        return nil
    }

    /// If not `nil`, there is a problem with CloudKit's import.
    public var importError: Error? {
        if networkAvailable == true, let error = importState.error {
            return error
        }
        return nil
    }

    /// If not `nil`, there is a real problem with CloudKit's export
    ///
    ///     if let error = SyncMonitor.shared.exportError {
    ///         print("Something needs to be fixed: \(error.localizedDescription)")
    ///     }
    ///
    /// This method is the main reason this module exists. When NSPersistentCloudKitContainer "stops working", it's because it's hit an error from which it
    /// can not recover. If that error happens during an export, it means your user's probably going to lose any changes they make (since iCloud is the
    /// "source of truth", and NSPersistentCloudKitContainer can't get their changes to iCloud).
    /// The key to data safety, then, is to detect and correct the error immediately. `exportError` is designed to detect this unrecoverable error state
    /// the moment it happens. It specifically tests that the network is available and that an error was reported (including error text). This means that sync
    /// _should_ be working (that is, they're online), but failed. The user, or your application, will likely need to take action to correct the problem.
    public var exportError: Error? {
        if networkAvailable == true, let error = exportState.error {
            return error
        }
        return nil
    }

    // MARK: - Specific Status Properties -

    /// The state of `NSPersistentCloudKitContainer`'s "setup" event
    @Published public private(set) var setupState: SyncState = .notStarted

    /// The state of `NSPersistentCloudKitContainer`'s "import" event
    @Published public private(set) var importState: SyncState = .notStarted

    /// The state of `NSPersistentCloudKitContainer`'s "export" event
    @Published public private(set) var exportState: SyncState = .notStarted

    /// Is the network available?
    ///
    /// This is true if the network is available in any capacity (Wi-Fi, Ethernet, cellular, carrier pidgeon, etc) - we just care if we can reach iCloud. 
    @Published public private(set) var networkAvailable: Bool? = nil

    @Published public private(set) var loggedIntoIcloud: Bool? = nil

    /// The current status of the user's iCloud account - updated automatically if they change it
    @Published public private(set) var iCloudAccountStatus: CKAccountStatus?

    /// If an error was encountered when retrieving the user's account status, this will be non-nil
    public private(set) var iCloudAccountStatusUpdateError: Error?

    // MARK: - Diagnosis properties -

    /// Contains the last Error encountered.
    ///
    /// This can be helpful in diagnosing "notSyncing" issues or other "partial error"s from which CloudKit thinks it recovered, but didn't really.
    public private(set) var lastError: Error?

    // MARK: - Listeners -

    /// Where we store Combine cancellables for publishers we're listening to, e.g. NSPersistentCloudKitContainer's notifications.
    private var disposables = Set<AnyCancellable>()

    /// Network path monitor that's used to track whether we can reach the network at all
    //    fileprivate let monitor: NetworkMonitor = NWPathMonitor()
    private let monitor = NWPathMonitor()

    /// The queue on which we'll run our network monitor
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")

    // MARK: - Initializers -

    /// Creates a new sync monitor and sets up listeners to sync and network changes
    public init(setupState: SyncState = .notStarted, importState: SyncState = .notStarted,
                exportState: SyncState = .notStarted, networkAvailable: Bool? = nil,
                iCloudAccountStatus: CKAccountStatus? = nil,
                lastErrorText: String? = nil,
                listen: Bool = true) {
        self.setupState = setupState
        self.importState = importState
        self.exportState = exportState
        self.networkAvailable = networkAvailable
        self.iCloudAccountStatus = iCloudAccountStatus
        if let e = lastErrorText {
            self.lastError = NSError(domain: e, code: 0, userInfo: nil)
        }

        guard listen else { return }

        // Monitor NSPersistentCloudKitContainer sync events
        if #available(iOS 14.0, macCatalyst 14.0, *) { // Crashes on 13.7 w/o this, even though we have @available
            NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
                .sink(receiveValue: { notification in
                    if let cloudEvent = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event {
                        let event = SyncEvent(from: cloudEvent) // To make testing possible
                        // Properties need to be set on the main thread for SwiftUI, so we'll do that here
                        // instead of maing setProperties run async code, which is inconvenient for testing.
                        DispatchQueue.main.async { self.setProperties(from: event) }
                    }
                })
                .store(in: &disposables)
        }

        // Update the network status when the OS reports a change. Note that we ignore whether the connection is
        // expensive or not - we just care whether iCloud is _able_ to sync. If there's no network,
        // NSPersistentCloudKitContainer will try to sync but report an error. We consider that a real error unless
        // the network is not available at all. If it's available but expensive, it's still an error.
        // Obstensively, if the user's device has iCloud syncing turned off (e.g. due to low power mode or not
        // allowing syncing over cellular connections), NSPersistentCloudKitContainer won't try to sync.
        // If that assumption is incorrect, we'll need to update the logic in this class.
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                #if os(watchOS)
                self.networkAvailable = (path.availableInterfaces.count > 0)
                #else
                self.networkAvailable = (path.status == .satisfied)
                #endif
            }
        }
        monitor.start(queue: monitorQueue)

        // Monitor changes to the iCloud account (e.g. login/logout)
        self.updateiCloudAccountStatus()
        NotificationCenter.default.publisher(for: .CKAccountChanged)
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink(receiveValue: { notification in
                self.updateiCloudAccountStatus()
            })
            .store(in: &disposables)
    }

    /// Convenience initializer that creates a SyncMonitor with preset state values for testing or previews
    ///
    ///     let syncMonitor = SyncMonitor(importSuccessful: false, errorText: "Cloud distrupted by weather net")
    public init(setupSuccessful: Bool = true, importSuccessful: Bool = true, exportSuccessful: Bool = true,
                networkAvailable: Bool = true, iCloudAccountStatus: CKAccountStatus = .available, errorText: String?) {
        var error: Error? = nil
        if let errorText = errorText {
            error = NSError(domain: errorText, code: 0, userInfo: nil)
        }
        let startDate = Date(timeIntervalSinceNow: -15) // a 15 second sync. :o
        let endDate = Date()
        self.setupState = setupSuccessful
            ? SyncState.succeeded(started: startDate, ended: endDate)
            : .failed(started: startDate, ended: endDate, error: error)
        self.importState = importSuccessful
            ? .succeeded(started: startDate, ended: endDate)
            : .failed(started: startDate, ended: endDate, error: error)
        self.exportState = exportSuccessful
            ? .succeeded(started: startDate, ended: endDate)
            : .failed(started: startDate, ended: endDate, error: error)
        self.networkAvailable = networkAvailable
        self.iCloudAccountStatus = iCloudAccountStatus
    }

    /// Checks the current status of the user's iCloud account and updates our iCloudAccountStatus property
    ///
    /// When SyncMonitor is listening to notifications (which it does unless you tell it not to when initializing), this method is called each time CKContainer
    /// fires off a `.CKAccountChanged` notification.
    private func updateiCloudAccountStatus() {
        CKContainer.default().accountStatus { (accountStatus, error) in
            DispatchQueue.main.async {
                if let e = error {
                    self.iCloudAccountStatusUpdateError = e
                } else {
                    self.iCloudAccountStatus = accountStatus
                }
            }
        }
    }

    // MARK: - Processing NSPersistentCloudKitContainer events -

    /// Set the appropriate State property (importState, exportState, setupState) based on the provided event
    internal func setProperties(from event: SyncEvent) {
        // First, set the SyncState for the event
        var state: SyncState = .notStarted
        // NSPersistentCloudKitContainer sends a notification when an event starts, and another when it
        // ends. If it has an endDate, it means the event finished.
        if let startDate = event.startDate, event.endDate == nil {
            state = .inProgress(started: startDate)
        } else if let startDate = event.startDate, let endDate = event.endDate {
            if event.succeeded {
                state = .succeeded(started: startDate, ended: endDate)
            } else {
                state = .failed(started: startDate, ended: endDate, error: event.error)
            }
        }

        switch event.type {
        case .setup:
            setupState = state
        case .import:
            importState = state
        case .export:
            exportState = state
        @unknown default:
            assertionFailure("NSPersistentCloudKitContainer added a new event type.")
        }

        if event.error != nil {
            lastError = event.error
        }
    }

    /// A sync event containing the values from NSPersistentCloudKitContainer.Event that we track
    internal struct SyncEvent {
        var type: NSPersistentCloudKitContainer.EventType
        var startDate: Date?
        var endDate: Date?
        var succeeded: Bool
        var error: Error?

        /// Creates a SyncEvent from explicitly provided values (for testing)
        init(type: NSPersistentCloudKitContainer.EventType, startDate: Date?, endDate: Date?, succeeded: Bool,
             error: Error?) {
            self.type = type
            self.startDate = startDate
            self.endDate = endDate
            self.succeeded = succeeded
            self.error = error
        }

        /// Creates a SyncEvent from an NSPersistentCloudKitContainer Event
        init(from cloudKitEvent: NSPersistentCloudKitContainer.Event) {
            self.type = cloudKitEvent.type
            self.startDate = cloudKitEvent.startDate
            self.endDate = cloudKitEvent.endDate
            self.succeeded = cloudKitEvent.succeeded
            self.error = cloudKitEvent.error
        }
    }

    // MARK: - Defining state -

    /// The state of a CloudKit import, export, or setup event as reported by an `NSPersistentCloudKitContainer` notification
    public enum SyncState {
        /// No event has been reported
        case notStarted

        /// A notification with a start date was received, but it had no end date.
        case inProgress(started: Date)

        /// The last sync of this type finished and succeeded (`succeeded` was `true` in the notification from `NSPersistentCloudKitContainer`).
        case succeeded(started: Date, ended: Date)

        /// The last sync of this type finished but failed (`succeeded` was `false` in the notification from `NSPersistentCloudKitContainer`).
        case failed(started: Date, ended: Date, error: Error?)

        /// Convenience property that returns true if the last sync of this type succeeded
        ///
        /// `succeeded` is true if the sync finished and reported true for its "succeeded" property.
        /// Otherwise (e.g.
        var succeeded: Bool {
            if case .succeeded = self { return true }
            return false
        }

        /// Convenience property that returns true if the last sync of this type failed
        var failed: Bool {
            if case .failed = self { return true }
            return false
        }

        /// Convenience property that returns the error returned if the event failed
        ///
        /// This is the main property you'll want to use to detect an error, as it will be `nil` if the sync is incomplete or succeeded, and will contain
        /// an `Error` if the sync finished and failed.
        ///
        ///     if let error = SyncMonitor.shared.exportState.error {
        ///         print("Sync failed: \(error.localizedDescription)")
        ///     }
        ///
        /// Note that this property will report all errors, including those caused by normal things like being offline.
        /// See also `SyncMonitor.importError` and `SyncMonitor.exportError` for more intelligent error reporting.
        var error: Error? {
            if case let .failed(_,_,error) = self, let e = error {
                return e
            }
            return nil
        }
    }
}
