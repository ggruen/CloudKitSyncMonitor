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

/// A class that monitors and reports the current state of `NSPersistentCloudKitContainer` synchronization.
///
/// `SyncMonitor` provides a comprehensive overview of the iCloud sync status for your Core Data stack using `NSPersistentCloudKitContainer`. It tracks setup, import, and export events, network availability, and iCloud account status to give you detailed insights into the sync process.
///
/// While `NSPersistentCloudKitContainer` typically handles synchronization automatically, `SyncMonitor` is particularly useful for detecting and responding to sync failures, which could potentially lead to data loss if not addressed.
///
/// - Important: Call `SyncMonitor.default.startMonitoring()` early in your app to promptly set up monitoring. Otherwise, monitoring will begin when `SyncMonitor.default` is first accessed, which could lead to inaccurate state information if properties are checked right away.
///
/// - Note: iCloud is considered the "source of truth" for `NSPersistentCloudKitContainer` data. A sync failure, especially during export, may result in local changes not being propagated to iCloud.
///
/// # Usage
///
/// ```swift
/// if SyncMonitor.default.hasSyncError {
///     if let error = SyncMonitor.default.setupError {
///         print("iCloud sync setup failed: \(error.localizedDescription)")
///     }
///     if let error = SyncMonitor.default.importError {
///         print("iCloud import failed: \(error.localizedDescription)")
///     }
///     if let error = SyncMonitor.default.exportError {
///         print("iCloud export failed: \(error.localizedDescription)")
///     }
/// } else if SyncMonitor.default.isNotSyncing {
///     print("Sync should be working, but isn't. Check for system-level issues.")
/// }
/// ```
///
/// # SwiftUI Integration
///
/// Observe `SyncMonitor` in your SwiftUI views:
///
/// ```swift
/// @StateObject private var syncMonitor = SyncMonitor.default
/// ```
///
/// Display a sync status icon:
///
/// ```swift
/// Image(systemName: syncMonitor.syncStateSummary.symbolName)
///     .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
/// ```
///
/// Show an icon only for sync errors:
///
/// ```swift
/// if syncMonitor.syncStateSummary.isBroken {
///     Image(systemName: syncMonitor.syncStateSummary.symbolName)
///         .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
/// }
/// ```
///
/// Display an icon during active syncing:
///
/// ```swift
/// if syncMonitor.syncStateSummary.isInProgress {
///     Image(systemName: syncMonitor.syncStateSummary.symbolName)
///         .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
/// }
/// ```
///
/// # Detailed Error Reporting
///
/// For a more granular view of sync status:
///
/// ```swift
/// Group {
///     if syncMonitor.hasSyncError {
///         VStack {
///             HStack {
///                 if syncMonitor.setupError != nil {
///                     Image(systemName: "xmark.icloud").foregroundColor(.red)
///                 }
///                 if syncMonitor.importError != nil {
///                     Image(systemName: "icloud.and.arrow.down").foregroundColor(.red)
///                 }
///                 if syncMonitor.exportError != nil {
///                     Image(systemName: "icloud.and.arrow.up").foregroundColor(.red)
///                 }
///             }
///         }
///     } else if syncMonitor.isNotSyncing {
///         Image(systemName: "xmark.icloud")
///     } else {
///         Image(systemName: "icloud").foregroundColor(.green)
///     }
/// }
/// ```
@MainActor
public class SyncMonitor: ObservableObject {
    /// The shared instance of `SyncMonitor`.
    public static let `default` = SyncMonitor()
    
    @available(*, deprecated, renamed: "default")
    public static var shared: SyncMonitor { `default` }
    
    // MARK: - Summary properties -
    
    /// A summary of the overall sync state.
    ///
    /// This property provides a high-level overview of the current sync status, which can be used to display a summary icon or message in your user interface.
    ///
    /// The sync state summary is determined as follows:
    /// - `.noNetwork`: The network is unavailable.
    /// - `.accountNotAvailable`: The iCloud account is not available (e.g., user not logged in or iCloud is disabled for the app).
    /// - `.error`: An error was reported for any event type during the last sync attempt.
    /// - `.notSyncing`: Sync should be working but isn't (see `isNotSyncing`).
    /// - `.notStarted`: All event types are in the `.notStarted` state.
    /// - `.inProgress`: At least one event type is in the `.inProgress` state.
    /// - `.succeeded`: All event types are in the `.succeeded` state.
    /// - `.unknown`: The sync state doesn't match any of the above conditions.
    ///
    /// - Returns: A `SyncSummaryStatus` enum value representing the current state of sync.
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
    
    /// Indicates whether `NSPersistentCloudKitContainer` has reported any sync errors.
    ///
    /// This property returns `true` if `setupError`, `importError`, or `exportError` is not `nil`.
    ///
    /// - Returns: A Boolean value indicating whether a sync error has been reported.
    public var hasSyncError: Bool {
        return setupError != nil || importError != nil || exportError != nil
    }
    
    /// Indicates whether sync should be functioning normally.
    ///
    /// Returns `true` if the user's iCloud account is available, the network is available, there are no recorded sync errors, and setup has completed successfully.
    ///
    /// - Returns: A Boolean value indicating whether sync should be operational.
    public var shouldBeSyncing: Bool {
        if case .available = iCloudAccountStatus, self.isNetworkAvailable == true, !hasSyncError,
           case .succeeded = setupState {
            return true
        }
        return false
    }
    
    @available(*, deprecated, renamed: "isNotSyncing")
    public var notSyncing: Bool { isNotSyncing }
    
    /// Detects a condition where CloudKit should be syncing but isn't.
    ///
    /// This property returns `true` if `shouldBeSyncing` is `true` but `importState` is still `.notStarted`.
    ///
    /// - Note: This condition should typically only occur briefly (less than a second) between setup completion and the start of the first import.
    ///
    /// - Important: If `isNotSyncing` remains `true` for an extended period, it may indicate an issue with `NSPersistentCloudKitContainer`. Consider filing a Feedback to Apple if you encounter this situation.
    public var isNotSyncing: Bool {
        if case .notStarted = importState, shouldBeSyncing {
            return true
        }
        return false
    }
    
    /// The error encountered during the CloudKit setup process, if any.
    ///
    /// If not `nil`, this indicates a significant problem that may prevent imports or exports from occurring, potentially leading to sync delays.
    ///
    /// - Returns: An `Error` object if there's a setup error, or `nil` if there's no error.
    public var setupError: Error? {
        if isNetworkAvailable == true, let error = setupState.error {
            return error
        }
        return nil
    }
    
    /// The error encountered during the CloudKit import process, if any.
    ///
    /// - Returns: An `Error` object if there's an import error, or `nil` if there's no error.
    public var importError: Error? {
        if isNetworkAvailable == true, let error = importState.error {
            return error
        }
        return nil
    }
    
    /// The error encountered during the CloudKit export process, if any.
    ///
    /// - Returns: An `Error` object if there's an export error, or `nil` if there's no error.
    ///
    /// - Important: An export error is particularly critical as it may result in local changes not being synchronized to iCloud. Prompt detection and correction of export errors is crucial for data integrity.
    public var exportError: Error? {
        if isNetworkAvailable == true, let error = exportState.error {
            return error
        }
        return nil
    }
    
    // MARK: - Specific Status Properties -
    
    /// The current state of the `NSPersistentCloudKitContainer` setup process.
    @Published public private(set) var setupState: SyncState = .notStarted
    
    /// The current state of the `NSPersistentCloudKitContainer` import process.
    @Published public private(set) var importState: SyncState = .notStarted
    
    /// The current state of the `NSPersistentCloudKitContainer` export process.
    @Published public private(set) var exportState: SyncState = .notStarted
    
    @available(*, deprecated, renamed: "isNetworkAvailable")
    public var networkAvailable: Bool? { isNetworkAvailable }
    
    /// Indicates whether the network is available for iCloud sync.
    ///
    /// - Returns: A Boolean value indicating network availability, or `nil` if the status is unknown.
    @Published public private(set) var isNetworkAvailable: Bool? = nil
    
    /// The current status of the user's iCloud account.
    ///
    /// This property is automatically updated if the account status changes.
    @Published public private(set) var iCloudAccountStatus: CKAccountStatus?
    
    @available(*, deprecated, renamed: "iCloudAccountStatusError")
    public var iCloudAccountStatusUpdateError: Error? { iCloudAccountStatusError }
    
    /// The error encountered when attempting to retrieve the user's iCloud account status, if any.
    public private(set) var iCloudAccountStatusError: Error?
    
    // MARK: - Diagnosis properties -
    
    @available(*, deprecated, renamed: "lastSyncError")
    public var lastError: Error? { lastSyncError }
    
    /// The most recent sync error encountered.
    ///
    /// This property can be useful for diagnosing issues related to `isNotSyncing` or other "partial" errors that CloudKit believes it recovered from but didn't.
    public private(set) var lastSyncError: Error?
    
    // MARK: - Private properties -
    
    /// Network path monitor that's used to track whether we can reach the network at all
    private let monitor = NWPathMonitor()
    
    /// Task for managing all monitoring activities
    private var monitoringTask: Task<Void, Error>?
    
    // MARK: - Initializers -
    
    private init() {
        _startMonitoring()
    }
    
    deinit {
        monitoringTask?.cancel()
    }
    
    #if DEBUG
    /// Convenience initializer that creates a `SyncMonitor` with preset state values for testing or previews
    ///
    /// - Parameters:
    ///   - isSetupSuccessful: A Boolean value indicating whether the setup was successful. Defaults to `true`.
    ///   - isImportSuccessful: A Boolean value indicating whether the import was successful. Defaults to `true`.
    ///   - isExportSuccessful: A Boolean value indicating whether the export was successful. Defaults to `true`.
    ///   - isNetworkAvailable: A Boolean value indicating whether the network is available. Defaults to `true`.
    ///   - iCloudAccountStatus: The iCloud account status. Defaults to `.available`.
    ///   - errorText: An optional String containing the error message to be used if any operation was not successful.
    ///
    /// - Warning: Available only in DEBUG mode.
    ///
    /// This initializer creates a `SyncMonitor` instance with predefined states for setup, import, and export operations.
    /// It also sets the network availability and iCloud account status. If an error text is provided, it creates an `NSError`
    /// with that text as the domain.
    ///
    /// The initializer simulates a 15-second sync operation for all successful states.
    ///
    /// # Example Usage
    ///
    /// ```swift
    /// let syncMonitor = SyncMonitor(isImportSuccessful: false, errorText: "Cloud disrupted by weather net")
    /// ```
    ///
    /// - Note: This initializer cancels the monitoring task started by the designated initializer.
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
    #endif
    
    /// Initializes and starts the shared instance of `SyncMonitor`.
    ///
    /// Call this method as early as possible in your app's lifecycle to ensure that `SyncMonitor.default` accurately reflects the system's status when first accessed.
    public func startMonitoring() {
        _ = SyncMonitor.default
    }
    
    // MARK: - Private methods -
    
    private func _startMonitoring() {
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
    
    /// Represents the overall status of iCloud sync.
    public enum SyncSummaryStatus {
        case noNetwork, accountNotAvailable, error, notSyncing, notStarted, inProgress, succeeded, unknown
        
        /// A SF Symbol name representing the current sync status.
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
        
        /// A localized description of the current sync status.
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
        
        /// A color suitable for displaying the status symbol.
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
        
        /// Indicates whether the current state represents a broken sync state.
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
        
        /// Indicates whether a sync operation is currently in progress.
        public var isInProgress: Bool {
            if case .inProgress = self {
                return true
            }
            return false
        }
    }
    
    /// Represents the state of a CloudKit import, export, or setup event.
    public enum SyncState: Equatable {
        case notStarted
        case inProgress(started: Date)
        case succeeded(started: Date, ended: Date)
        case failed(started: Date, ended: Date, error: Error?)
        
        /// Indicates whether the last sync of this type succeeded.
        var didSucceed: Bool {
            if case .succeeded = self { return true }
            return false
        }
        
        /// Indicates whether the last sync of this type failed.
        var didFail: Bool {
            if case .failed = self { return true }
            return false
        }
        
        /// The error returned if the event failed, or `nil` if the sync is incomplete or succeeded.
        ///
        /// - Important: This property reports all errors, including those caused by normal conditions like being offline. For more intelligent error reporting, see `SyncMonitor.importError` and `SyncMonitor.exportError`.
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
