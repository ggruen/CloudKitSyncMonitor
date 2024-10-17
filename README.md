# CloudKitSyncMonitor

`CloudKitSyncMonitor` is a Swift package that listens to notifications sent out by `NSPersistentCloudKitContainer` and translates them into published properties, providing your app with real-time sync state information.

This package addresses a critical issue where CloudKit (and consequently your app) may cease syncing without warning or user notification. `CloudKitSyncMonitor` offers immediate detection of such scenarios, allowing you to promptly inform users and take appropriate action.

[![Swift Version](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey.svg)](https://developer.apple.com/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)

## Features and Behavior 🌟

### Core Functionality 🛠️

- 📡 Monitors sync status by intercepting and interpreting `NSPersistentCloudKitContainer` notifications
- 🧠 Intelligently assesses sync health by considering both network availability and iCloud account status
- 🔍 Exposes a `SyncMonitor` class, conveniently accessible via the `SyncMonitor.default` singleton

### Notification Subscriptions 📬

`SyncMonitor` actively subscribes to notifications from key system components:
- 🔄 `NSPersistentCloudKitContainer`: For core sync event monitoring
- ☁️ `CKContainer`: To track CloudKit-specific states
- 🌐 `NWPathMonitor`: For network status updates

**Important:** ⚠️ To ensure accurate and timely state information, call `SyncMonitor.default.startMonitoring()` as early as possible in your app's lifecycle, preferably in your app delegate or initial view.

### Information Levels 📊

`SyncMonitor` provides sync information at two distinct levels of granularity:

#### Top Level
The `syncStateSummary` property offers a high-level enum summarizing the overall sync state. This is ideal for quick status checks and user-facing information.

#### Detailed Level
`SyncMonitor` tracks the states of `NSPersistentCloudKitContainer`'s three primary event types:
   - Setup: Initialization of the sync environment
   - Import: Incoming data from CloudKit to the local store
   - Export: Outgoing data from the local store to CloudKit

   To monitor these events, `SyncMonitor` provides corresponding properties:
   - `setupState`: Tracks the state of the setup event
   - `importState`: Monitors the state of the import event
   - `exportState`: Follows the state of the export event
   
   These properties provide comprehensive information about each sync phase, including convenience methods for extracting commonly needed details.

### Problem Detection 🚨

`SyncMonitor` offers robust tools for identifying sync issues:

#### General Detection
- 🔴 `hasSyncError`: A Boolean indicating the presence of any sync-related error
- 🟡 `isNotSyncing`: Detects scenarios where sync should be operational but isn't functioning as expected

#### Specific Error Information
- `setupError`: Captures issues during the sync setup phase
- `importError`: Identifies problems with data import from CloudKit
- `exportError`: Highlights issues when exporting data to CloudKit

### Special Properties 🔑

The `isNotSyncing` property is particularly useful for detecting subtle sync issues:
- It indicates when setup has completed successfully, but no import event has started, and no errors have been reported
- This can reveal edge cases like OS-level password re-entry prompts, where CloudKit considers the account "available", but `NSPersistentCloudKitContainer` is unable to initiate sync
- Like other properties, it factors in network availability and iCloud account status for accurate reporting

### Importance of Error Detection ⚠️

Timely and accurate error detection is crucial for maintaining data integrity and user trust:

1. 🛡️ Prevents potential data loss by identifying sync failures before they lead to conflicts or data divergence
2. ⚡ Enables immediate detection and reporting of sync anomalies, often before users notice any issues
3. 😊 Significantly enhances user experience by providing transparent, real-time sync status information
4. 🏆 Helps maintain app reliability and data consistency across devices

### Detailed Sync Information 📋

The `setupState`, `importState`, and `exportState` properties offer comprehensive insights into the sync process:
- Current state of each event type (not started, in progress, succeeded, or failed)
- Precise start and end times for each sync event
- Detailed error information when applicable

Example usage for displaying detailed sync status:

```swift
fileprivate var dateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .short
    dateFormatter.timeStyle = .short
    return dateFormatter
}()

print("Setup state: \(stateText(for: SyncMonitor.default.setupState))")
print("Import state: \(stateText(for: SyncMonitor.default.importState))")
print("Export state: \(stateText(for: SyncMonitor.default.exportState))")

func stateText(for state: SyncMonitor.SyncState) -> String {
    switch state {
    case .notStarted:
        return "Not started"
    case .inProgress(started: let date):
        return "In progress since \(dateFormatter.string(from: date))"
    case let .succeeded(started: _, ended: endDate):
        return "Succeeded at \(dateFormatter.string(from: endDate))"
    case let .failed(started: _, ended: endDate, error: _):
        return "Failed at \(dateFormatter.string(from: endDate))"
    }
}
```

For more detailed information on all available properties and methods, please refer to the comprehensive SyncMonitor documentation.

## Usage Examples 🚀

### Handle Errors

```swift
private let syncMonitor = SyncMonitor.default

if syncMonitor.hasSyncError {
    if let error = syncMonitor.setupError {
        print("Unable to set up iCloud sync, changes won't be saved! \(error.localizedDescription)")
    }
    if let error = syncMonitor.importError {
        print("Import is broken: \(error.localizedDescription)")
    }
    if let error = syncMonitor.exportError {
        print("Export is broken - your changes aren't being saved! \(error.localizedDescription)")
    }
} else if syncMonitor.isNotSyncing {
    print("Sync should be working, but isn't. Look for a badge on Settings or other possible issues.")
}
```

### Display Error Status

```swift
import CloudKitSyncMonitor

struct SyncStatusView: View {
    
    @StateObject private var syncMonitor = SyncMonitor.default

    var body: some View {
         if syncMonitor.syncStateSummary.isBroken {
             Image(systemName: syncMonitor.syncStateSummary.symbolName)
                 .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
         }
    }
}
```

### Display Current Sync State

```swift
import CloudKitSyncMonitor

struct SyncStatusView: View {
    
    @StateObject private var syncMonitor = SyncMonitor.default

    var body: some View {
        Image(systemName: syncMonitor.syncStateSummary.symbolName)
            .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
    }
}
```

### Conditional Display

```swift
if syncMonitor.syncStateSummary.isBroken || syncMonitor.syncStateSummary.isInProgress {
    Image(systemName: syncMonitor.syncStateSummary.symbolName)
        .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
}
```

### Check for Specific States

```swift
if case .accountNotAvailable = syncMonitor.syncStateSummary {
    Text("Hey, log into your iCloud account if you want to sync")
}
```

## Installation 📦

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ggruen/CloudKitSyncMonitor.git", from: "3.0.0"),
],
targets: [
    .target(
        name: "MyApp", // Where "MyApp" is the name of your app
        dependencies: ["CloudKitSyncMonitor"]),
]
```

### Xcode

1. Select File » Swift Packages » Add Package Dependency...
2. Enter the repository URL: `https://github.com/ggruen/CloudKitSyncMonitor.git`
3. Choose "Up to next major version" with `3.0.0` as the minimum version.

## Development 🛠️

- 🍴 Fork repository
- 📥 Check out on your development system
- 📁 Drag the folder this README is in (CloudKitSyncMonitor) into your Xcode project or workspace. This will make Xcode choose the
  local version over the version in the package manager.
- 🔧 If you haven't added it via File > Swift Packages already, go into your project > General tab > Frameworks, Libraries and Embedded Content,
  and click the + button to add it. You may need to quit and re-start Xcode to make the new package appear in the list so you can select it.
- 🖊️ Make your changes, commit and push to Github
- 🚀 Submit pull request

To go back to using the github version, just remove CloudKitSyncMonitor (click on it, hit the delete key, choose to remove reference)
from the side bar - Xcode should fall back to the version you added using the Installation instructions above. If you _haven't_ installed
it as a package dependency yet, then just delete it from the side bar and then add it as a package dependency using the Installation
instructions above.

You can also submit issues if you find bugs, have suggestions or questions, etc. 🐛💡❓
