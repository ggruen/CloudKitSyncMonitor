# CloudKitSyncMonitor

`CloudKitSyncMonitor` listens to the notifications sent out by `NSPersistentCloudKitContainer`
and translates them into a few published properties that can give your app the current state of its sync.

The primary use for this is to detect that rare condition in which CloudKit (and therefore your app) will just stop syncing with no warning and
no notification to the user. Well, now there's an immediate warning, and you can notify the user.

This SwiftUI view will display a red error image at the top of the screen if there's a sync error:

```swift
import CloudKitSyncMonitor
struct SyncStatusView: View {
    @available(iOS 15.0, *)
    @ObservedObject var syncMonitor = SyncMonitor.shared

    var body: some View {
        // Show sync status if there's a sync error 
         if #available(iOS 15.0, *), syncMonitor.syncStateSummary.isBroken {
             Image(systemName: syncMonitor.syncStateSummary.symbolName)
                 .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
         }
    }
}
```

This will show an image that indicates the current state of sync (it's the same as above with `syncMonitor.syncStateSummary.isBroken`
removed):

```swift
import CloudKitSyncMonitor
struct SyncStatusView: View {
    @available(iOS 15.0, *)
    @ObservedObject var syncMonitor = SyncMonitor.shared

    var body: some View {
        // Show sync status 
        if #available(iOS 15.0, *) {
            Image(systemName: syncMonitor.syncStateSummary.symbolName)
                .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
        }
    }
}
```

You could change the if clause to this to display an icon only when a sync is in progress or there's an error:

```swift
if #available(iOS 15.0, *),
    (syncMonitor.syncStateSummary.isBroken || syncMonitor.syncStateSummary.inProgress) {
    Image(systemName: syncMonitor.syncStateSummary.symbolName)
        .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
}
```

Or check for specific states:

```swift
if #available(iOS 15.0, *), case .accountNotAvailable = syncMonitor.syncStateSummary {
    Text("Hey, log into your iCloud account if you want to sync")
}
```

`CloudKitSyncMonitor` takes the network availablity and the user's iCloud account availablity into account when considering sync
to be "broken". e.g. if the user is on an airplane, or not logged into iCloud, `CloudKitSyncMonitor` doesn't consider sync to be `isBroken`.

The `CloudKitSyncMonitor` package provides a class called `SyncMonitor`, which you can use as a singleton in your app via
`SyncMonitor.shared`.

`SyncMonitor` subscribes to notifications from relevant services (e.g. `NSPersistentCloudKitContainer`,
`CKContainer`, and `NWPathMonitor`), and uses them to update its properties, which are then published via `Combine`.

`SyncMonitor` is designed to give you different levels of detail based on how much information you want.

At the top (most general) level, it provides `syncStateSummary`, a property that returns a summary of the state of sync as an enum.
The above examples show some uses of `syncStateSummary` - more info is available in the method's documentation comments.

At more detailed levels, `NSPersistentCloudKitContainer` (and therefore `SyncMonitor`) refer to three different kinds of "events":
Setup, Import, and Export.

`SyncMonitor` stores the current state of each of these types of events in `setupState`, `importState`, and `exportState` respectively,
and provides convenience methods to extract commonly-needed information from these.

You can tell if there's a sync problem by checking the `syncError` and `notSyncing` properties, and get error details from the `setupError`,
`importError`, and `exportError` computed properties.

This code will detect if there's a sync issue that your user, or your app, needs to do something about:

```swift
// If true, either setupError, importError or exportError will contain an error
if SyncMonitor.shared.syncError {
    if let e = SyncMonitor.shared.setupError {
        print("Unable to set up iCloud sync, changes won't be saved! \(e.localizedDescription)")
    }
    if let e = SyncMonitor.shared.importError {
        print("Import is broken: \(e.localizedDescription)")
    }
    if let e = SyncMonitor.shared.exportError {
        print("Export is broken - your changes aren't being saved! \(e.localizedDescription)")
    }
} else if SyncMonitor.shared.notSyncing {
    print("Sync should be working, but isn't. Look for a badge on Settings or other possible issues.")
}
```

 `notSyncing` is a special property that tells you when `SyncMonitor` has noticed that `NSPersistentCloudKitContainer` reported that
its "setup" event completed successfully, but that no "import" event was started, and no errors were reported. This can happen, for example,
if the OS has presented a "please re-enter your password" notification/popup (in which case, CloudKit consider's the user's account
"available", but NSPersistentCloudKitContainer won't actually be able to sync). `notSyncing`, like `isBroken`, take things like network
availabity and the user's iCloud login status into account.

Detecting error conditions is important because the usual "fix" for CloudKit not syncing is to delete the local database. This
is fine if your import stopped working, but if the export stopped working, this means that your user will lose any changes they made between
the time the sync failed and when it was detected. Previously, that time was based on when the user looked at two devices and noticed that
they didn't contain the same data. With `CloudKitSyncMonitor`, your app can report (or act on) that failure _immediately_, saving your
user's data and your app's reputation.

For more detail, the `setupState`, `importState`, and `exportState` properties return enum values that contain other details provided by
`NSPersistentCloudKitContainer`, e.g. the start and end times of each event.

You could, for example, display details about the user's sync status includng when sync events started and finished like this:

```swift
fileprivate var dateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = DateFormatter.Style.short
    dateFormatter.timeStyle = DateFormatter.Style.short
    return dateFormatter
}()

print("Setup state: \(stateText(for: SyncMonitor.shared.setupState))")
print("Import state: \(stateText(for: SyncMonitor.shared.importState))")
print("Export state: \(stateText(for: SyncMonitor.shared.exportState))")

/// Returns a user-displayable text description of the sync state
func stateText(for state: SyncMonitor.SyncState) -> String {
    switch state {
    case .notStarted:
        return "Not started"
    case .inProgress(started: let date):
        return "In progress since \(dateFormatter.string(from: date))"
    case let .succeeded(started: _, ended: endDate):
        return "Suceeded at \(dateFormatter.string(from: endDate))"
    case let .failed(started: _, ended: endDate, error: _):
        return "Failed at \(dateFormatter.string(from: endDate))"
    }
}
```

For more information, refer to the documentation in SyncMonitor.

# Installation

`CloudKitSyncMonitor` is a swift package - add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ggruen/CloudKitSyncMonitor.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp", // Where "MyApp" is the name of your app
        dependencies: ["CloudKitSyncMonitor"]),
]
```

Or, in Xcode, you can select File » Swift Packages » Add Package Dependency... and specify the repository URL
`https://github.com/ggruen/CloudKitSyncMonitor.git` and "up to next major version" `1.0.0`.

# Development

- Fork repository
- Check out on your development system
- Drag the folder this README is in (CloudKitSyncMonitor) into your Xcode project or workspace. This will make Xcode choose the
  local version over the version in the package manager.
- If you haven't added it via File > Swift Packages already, go into your project > General tab > Frameworks, Libraries and Embedded Content,
  and click the + button to add it. You may need to quit and re-start Xcode to make the new package appear in the list so you can select it.
- Make your changes, commit and push to Github
- Submit pull request

To go back to using the github version, just remove CloudKitSyncMonitor (click on it, hit the delete key, choose to remove reference)
from the side bar - Xcode should fall back to the version you added using the Installation instructions above. If you _haven't_ installed
it as a package dependency yet, then just delete it from the side bar and then add it as a package dependency using the Installation
instructions above.

You can also submit issues if you find bugs, have suggestions or questions, etc.
