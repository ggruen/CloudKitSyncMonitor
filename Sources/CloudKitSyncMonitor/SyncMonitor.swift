//
//  SyncMonitor.swift
//
//
//  Created by Grant Grueninger on 9/23/20.
//  Updated by JP Toro on 9/28/24.
//

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
///     if SyncMonitor.shared.hasSyncError {
///         if let e = SyncMonitor.shared.setupError {
///             print("Unable to set up iCloud sync, changes won't be saved! \(e.localizedDescription)")
///         }
///         if let e = SyncMonitor.shared.importError {
///             print("Import is broken: \(e.localizedDescription)")
///         }
///         if let e = SyncMonitor.shared.exportError {
///             print("Export is broken - your changes aren't being saved! \(e.localizedDescription)")
///         }
///     } else if SyncMonitor.shared.isNotSyncing {
///         print("Sync should be working, but isn't. Look for a badge on Settings or other possible issues.")
///     }
///
/// `hasSyncError` and `isNotSyncing`, together, tell you if there's a problem that `NSPersistentCloudKitContainer` has announced or not announced
/// (respectively).
/// The `setupError`, `importError`, and `exportError` properties can give you the reported error. Digging deeper, `setupState`, `importState`,
/// and `exportState` give you the state of each type of `NSPersistentCloudKitContainer` event in a nice little `SyncState` enum with associated
/// values that let you get even more granular, e.g. to find whether each type of event is in progress, succeeded, or failed, the start and end time of the event, and
/// any error reported if the event failed.
///
/// *Some example code to use in SwiftUI views*
///
/// First, observe the shared syncmonitor instance so your view will update if the state changes:
///
///     @StateObject private var syncMonitor: SyncMonitor = SyncMonitor.shared
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
///     if syncMonitor.syncStateSummary.isInProgress {
///         Image(systemName: syncMonitor.syncStateSummary.symbolName)
///             .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
///     }
///
/// Show a detailed error reporting graphic - shows which type(s) of events are failing.
///
///     Group {
///         if syncMonitor.hasSyncError {
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
///         } else if syncMonitor.isNotSyncing {
///             Image(systemName: "xmark.icloud")
///         } else {
///             Image(systemName: "icloud").foregroundColor(.green)
///         }
///     }
///
@MainActor
public class SyncMonitor: ObservableObject {
    /// A singleton to use
    public static let shared = SyncMonitor()
    
    // MARK: - Summary properties -
    
    /// Returns an overview of the state of sync, which you could use to display a summary icon
    ///
    /// The general sync state is determined as follows:
    /// - If the network isn't available, the state summary is `.noNetwork`.
    /// - Otherwise, if the iCloud account isn't available (e.g., they're not logged in or have disabled iCloud for the app in Settings or System Preferences), the
    ///     state summary is `.accountNotAvailable`.
    /// - Otherwise, if `NSPersistentCloudKitContainer` reported an error for any event type the last time that event type ran, the state summary is
    ///     `.error`.
    /// - Otherwise, if `isNotSyncing` is true, the state is `.notSyncing`.
    /// - Otherwise, if all event types are `.notStarted`, the state is `.notStarted`.
    /// - Otherwise, if any event type is `.inProgress`, the state is `.inProgress`.
    /// - Otherwise, if all event types are `.succeeded`, the state is `.succeeded`.
    /// - Otherwise, the state is `.unknown`.
    ///
    /// Here's how you might use this in a SwiftUI view:
    ///
    ///     @StateObject private var syncMonitor: SyncMonitor = SyncMonitor.shared
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
    ///     if syncMonitor.syncStateSummary.isInProgress {
    ///         Image(systemName: syncMonitor.syncStateSummary.symbolName)
    ///             .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
    ///     }
    ///
    public var syncStateSummary: SyncSummaryStatus {
        if isNetworkAvailable == false { return .noNetwork }
        if let iCloudAccountStatus, iCloudAccountStatus != .available { return .accountNotAvailable }
        if hasSyncError { return .error }
        if isNotSyncing { return .notSyncing }
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
    
    @available(*, deprecated, renamed: "hasSyncError")
    public var syncError: Bool { hasSyncError }
    
    /// Returns true if `NSPersistentCloudKitContainer` has reported an error.
    ///
    /// This is a convenience property that returns true if `setupError`, `importError` or `exportError` is not nil.
    /// If `hasSyncError` is true, then either `setupError`, `importError` or `exportError` (or any combination of them)) will contain an error object.
    ///
    ///     // If true, either setupError, importError or exportError will contain an error
    ///     if SyncMonitor.shared.hasSyncError {
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
    /// `hasSyncError` being `true` means that `NSPersistentCloudKitContainer` sent a notification that included an error.
    public var hasSyncError: Bool {
        return setupError != nil || importError != nil || exportError != nil
    }
    
    /// Returns `true` if there's no reason that we know of why sync shouldn't be working
    ///
    /// That is, the user's iCloud account status is "available", the network is available, there are no recorded sync errors, and setup is complete and succeeded.
    public var shouldBeSyncing: Bool {
        if case .available = iCloudAccountStatus, self.isNetworkAvailable == true, !hasSyncError,
           case .succeeded = setupState {
            return true
        }
        return false
    }
    
    @available(*, deprecated, renamed: "isNotSyncing")
    public var notSyncing: Bool { isNotSyncing }
    
    /// Detects a condition in which CloudKit _should_ be syncing, but isn't.
    ///
    /// `isNotSyncing` is true if `shouldBeSyncing` is true (see `shouldBeSyncing`) but `importState` is still `.notStarted`.
    ///
    /// The first thing `NSPersistentCloudKitContainer` does when the app starts is to set up, then run an import. So, `isNotSyncing` should be true for
    /// a very very short period of time (e.g. less than a second) for the time between when setup completes and the import starts. As such, it's suitable for
    /// displaying an error graphic to the user, e.g. `Image(systemName: "xmark.icloud")` if `isNotSyncing` is `true`, but not necessarily for
    /// programmatic action (unless isNotSyncing stays true for more than a few seconds).
    ///
    ///     if SyncMonitor.shared.hasSyncError {
    ///         // Act on error
    ///     } else if SyncMonitor.shared.isNotSyncing {
    ///         print("Sync should be working, but isn't. Look for a badge on Settings or other possible issues.")
    ///     }
    ///
    /// I would argue that `isNotSyncing` being `true` for a longer period of time indicates a bug in `NSPersistentCloudKitContainer`. E.g. the case
    /// that made me write this computed property is that if Settings on iOS wants the user to log in again, CloudKit will report a "partial error" when setting up,
    /// but ultimately send a notification stating that setup was successful; however, CloudKit will then just not sync, providing no errors. `isNotSyncing` detects
    /// this condition, and those like it. If you see `isNotSyncing` being triggered, I'd recommend isolating the issue (e.g., the one above) and filing a FB about it
    /// to Apple.
    public var isNotSyncing: Bool {
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
    /// You should examine the error for the cause. You may then be able to at least report it to the user, if not automate a "fix" in your app.
    public var setupError: Error? {
        if isNetworkAvailable == true, let error = setupState.error {
            return error
        }
        return nil
    }
    
    /// If not `nil`, there is a problem with CloudKit's import.
    public var importError: Error? {
        if isNetworkAvailable == true, let error = importState.error {
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
    /// cannot recover. If that error happens during an export, it means your user's probably going to lose any changes they make (since iCloud is the
    /// "source of truth", and NSPersistentCloudKitContainer can't get their changes to iCloud).
    /// The key to data safety, then, is to detect and correct the error immediately. `exportError` is designed to detect this unrecoverable error state
    /// the moment it happens. It specifically tests that the network is available and that an error was reported (including error text). This means that sync
    /// _should_ be working (that is, they're online), but failed. The user, or your application, will likely need to take action to correct the problem.
    public var exportError: Error? {
        if isNetworkAvailable == true, let error = exportState.error {
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
    
    @available(*, deprecated, renamed: "isNetworkAvailable")
    public var networkAvailable: Bool? { isNetworkAvailable }
    
    /// Is the network available?
    ///
    /// This is true if the network is available in any capacity (Wi-Fi, Ethernet, cellular, carrier pigeon, etc.) - we just care if we can reach iCloud.
    @Published public private(set) var isNetworkAvailable: Bool? = nil
    
    /// The current status of the user's iCloud account - updated automatically if they change it
    @Published public private(set) var iCloudAccountStatus: CKAccountStatus?
    
    @available(*, deprecated, renamed: "iCloudAccountStatusError")
    public var iCloudAccountStatusUpdateError: Error? { iCloudAccountStatusError }
    
    /// If an error was encountered when retrieving the user's account status, this will be non-nil
    public private(set) var iCloudAccountStatusError: Error?
    
    // MARK: - Diagnosis properties -
    
    @available(*, deprecated, renamed: "lastSyncError")
    public var lastError: Error? { lastSyncError }
    
    /// Contains the last sync Error encountered.
    ///
    /// This can be helpful in diagnosing "isNotSyncing" issues or other "partial" errors from which CloudKit thinks it recovered, but didn't really.
    public private(set) var lastSyncError: Error?
    
    // MARK: - Private properties -
    
    /// Network path monitor that's used to track whether we can reach the network at all
    private let monitor = NWPathMonitor()
    
    /// Task for managing all monitoring activities
    private var monitoringTask: Task<Void, Error>?
    
    // MARK: - Initializers -
    
    /// Creates a new sync monitor and sets up listeners to sync and network changes
    public init() {
        startMonitoring()
    }
    
    deinit {
        monitoringTask?.cancel()
    }
    
    /// Convenience initializer that creates a SyncMonitor with preset state values for testing or previews
    ///
    ///     let syncMonitor = SyncMonitor(isImportSuccessful: false, errorText: "Cloud disrupted by weather net")
    public convenience init(
        isSetupSuccessful: Bool = true,
        isImportSuccessful: Bool = true,
        isExportSuccessful: Bool = true,
        isNetworkAvailable: Bool = true,
        iCloudAccountStatus: CKAccountStatus = .available,
        errorText: String?
    ) {
        self.init()  // Call the designated initializer
        
        var error: Error? = nil
        if let errorText = errorText {
            error = NSError(domain: errorText, code: 0, userInfo: nil)
        }
        let startDate = Date(timeIntervalSinceNow: -15) // a 15 second sync
        let endDate = Date()
        
        self.setupState = isSetupSuccessful
            ? SyncState.succeeded(started: startDate, ended: endDate)
            : .failed(started: startDate, ended: endDate, error: error)
        self.importState = isImportSuccessful
            ? .succeeded(started: startDate, ended: endDate)
            : .failed(started: startDate, ended: endDate, error: error)
        self.exportState = isExportSuccessful
            ? .succeeded(started: startDate, ended: endDate)
            : .failed(started: startDate, ended: endDate, error: error)
        self.isNetworkAvailable = isNetworkAvailable
        self.iCloudAccountStatus = iCloudAccountStatus
        self.lastSyncError = error
        
        // Cancel the monitoring task started by the designated initializer
        self.monitoringTask?.cancel()
        self.monitoringTask = nil
    }
    
    /// Ensures that the shared instance of `SyncMonitor` is initialized.
    ///
    /// This method initializes the shared instance, if uninitialized, starting the process of
    /// setting up event listeners, monitoring network changes, and checking iCloud account status.
    /// Call this method as early as possible to help ensure status properties are not `nil` when first checked.
    public static func configure() {
        _ = shared
    }
    
    // MARK: - Private methods -
    
    private func startMonitoring() {
        monitoringTask = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.listenToSyncEvents() }
                group.addTask { try await self.monitorNetworkChanges() }
                group.addTask { await self.monitorICloudAccountStatus() }
                
                try await group.waitForAll()
            }
        }
    }
    
    /// Listens to NSPersistentCloudKitContainer eventChangedNotification using async/await
    private func listenToSyncEvents() async throws {
        let notificationCenter = NotificationCenter.default
        let syncEventStream = notificationCenter.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification)
            .compactMap { notification -> SyncEvent? in
                guard let cloudKitEvent = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else {
                    return nil
                }
                return SyncEvent(from: cloudKitEvent)
            }
        
        for await event in syncEventStream {
            try Task.checkCancellation()
            processSyncEvent(event)
        }
    }
    
    /// Monitors network changes asynchronously
    private func monitorNetworkChanges() async throws {
        for await path in networkPathUpdates() {
            try Task.checkCancellation()
            #if os(watchOS)
            self.isNetworkAvailable = (path.availableInterfaces.count > 0)
            #else
            self.isNetworkAvailable = (path.status == .satisfied)
            #endif
        }
    }

    private func monitorICloudAccountStatus() async {
        // See https://stackoverflow.com/a/77072667 for .map() usage
        let accountChangedStream = NotificationCenter.default.notifications(named: .CKAccountChanged).map { _ in () }
        for await _ in accountChangedStream {
            await updateICloudAccountStatus()
        }
    }
    
    private func updateICloudAccountStatus() async {
        do {
            let status = try await CKContainer.default().accountStatus()
            self.iCloudAccountStatus = status
            self.iCloudAccountStatusError = nil
        } catch {
            self.iCloudAccountStatusError = error
        }
    }
    
    private func networkPathUpdates() -> AsyncStream<NWPath> {
        AsyncStream { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
            monitor.start(queue: DispatchQueue.global())
            
            continuation.onTermination = { @Sendable _ in
                self.monitor.cancel()
            }
        }
    }
    
    /// Set the appropriate State property (importState, exportState, setupState) based on the provided event
    private func processSyncEvent(_ event: SyncEvent) {
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
        
        if case .failed(_, _, let error) = state, let error {
            self.lastSyncError = error
        }
    }
    
    // MARK: - Helper types -
    
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
        
        /// A string you could use to display the status
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
            case .noNetwork, .accountNotAvailable, .notStarted, .inProgress:
                return .gray
            case .error, .notSyncing, .unknown:
                return .red
            case .succeeded:
                return .green
            }
        }
        
        /// Returns true if the state indicates that sync is broken
        public var isBroken: Bool {
            switch self {
            case .error, .notSyncing, .unknown:
                return true
            default:
                return false
            }
        }
        
        @available(*, deprecated, renamed: "isInProgress")
        public var inProgress: Bool { isInProgress }
        
        /// Convenience accessor that returns true if a sync is in progress
        public var isInProgress: Bool {
            if case .inProgress = self {
                return true
            }
            return false
        }
    }
    
    /// The state of a CloudKit import, export, or setup event as reported by an `NSPersistentCloudKitContainer` notification
    public enum SyncState: Equatable {
        /// No event has been reported
        case notStarted
        
        /// A notification with a start date was received, but it had no end date.
        case inProgress(started: Date)
        
        /// The last sync of this type finished and succeeded (`succeeded` was `true` in the notification from `NSPersistentCloudKitContainer`).
        case succeeded(started: Date, ended: Date)
        
        /// The last sync of this type finished but failed (`succeeded` was `false` in the notification from `NSPersistentCloudKitContainer`).
        case failed(started: Date, ended: Date, error: Error?)
        
        /// Convenience property that returns true if the last sync of this type succeeded
        var didSucceed: Bool {
            if case .succeeded = self { return true }
            return false
        }
        
        /// Convenience property that returns true if the last sync of this type failed
        var didFail: Bool {
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
            if case .failed(_, _, let error) = self, let error {
                return error
            }
            return nil
        }
        
        public static func == (lhs: SyncState, rhs: SyncState) -> Bool {
            switch (lhs, rhs) {
            case (.notStarted, .notStarted):
                return true
                
            case (.inProgress(let lhsStarted), .inProgress(let rhsStarted)):
                return lhsStarted == rhsStarted
                
            case (.succeeded(let lhsStarted, let lhsEnded), .succeeded(let rhsStarted, let rhsEnded)):
                return lhsStarted == rhsStarted && lhsEnded == rhsEnded
                
            case (.failed(let lhsStarted, let lhsEnded, let lhsError), .failed(let rhsStarted, let rhsEnded, let rhsError)):
                
                let datesEqual = lhsStarted == rhsStarted && lhsEnded == rhsEnded
                
                // Since Error doesn't conform to Equatable, we'll compare their localized descriptions
                let errorsEqual: Bool
                switch (lhsError, rhsError) {
                case (nil, nil):
                    errorsEqual = true
                case (let lhsErr?, let rhsErr?):
                    errorsEqual = lhsErr.localizedDescription == rhsErr.localizedDescription
                default:
                    errorsEqual = false
                }
                
                return datesEqual && errorsEqual
                
            default:
                return false
            }
        }
    }
    
    /// A sync event containing the values from NSPersistentCloudKitContainer.Event that we track
    internal struct SyncEvent {
        var type: NSPersistentCloudKitContainer.EventType
        var startDate: Date?
        var endDate: Date?
        var succeeded: Bool
        var error: Error?
        
        /// Creates a SyncEvent from an NSPersistentCloudKitContainer Event
        init(from cloudKitEvent: NSPersistentCloudKitContainer.Event) {
            self.type = cloudKitEvent.type
            self.startDate = cloudKitEvent.startDate
            self.endDate = cloudKitEvent.endDate
            self.succeeded = cloudKitEvent.succeeded
            self.error = cloudKitEvent.error
        }
    }
}
