# CloudKitSyncStatus

`CloudKitSyncStatus` listens to the notifications sent out by `NSPersistentCloudKitContainer`
and translates them into a few published properties that can give your app a current state of its sync.

The primary use for this is to detect that rare condition in which CloudKit (and therefore your app) will just stop syncing with no warning and
no notification to the user. Well, now there's an immediate warning, and you can notify the user.

This SwiftUI view will display a red error image at the top of the screen if there's an import or export error:

    import CloudKitSyncStatus
    struct SyncStatusView: View {
        @available(iOS 14.0, *)
        @ObservedObject var syncStatus = SyncStatus.shared

        var body: some View {
            // Report only on real sync errors
            if #available(iOS 14.0, *), (syncStatus.importError || syncStatus.exportError) {
                VStack {
                    HStack {
                        if syncStatus.importError {
                            Image(systemName: "icloud.and.arrow.down").foregroundColor(.red)
                        }
                        if syncStatus.exportError {
                            Image(systemName: "icloud.and.arrow.up").foregroundColor(.red)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

`CloudKitSyncStatus` has a few "magic" properties, which are featured in the example above, and are what you
really should use. Avoid the temptation to offer a continuous "sync status", and _absolutely_ avoid the temptation to detect when "sync is
finished", as in a distributed environment (such as the one your app is creating when you use `NSPersistentCloudKitContainer`), sync is
never "finished", and you're asking for "bad things", "unpredictable results", etc if you attempt to detect "sync is finished".

Anyway, the following properties take the state of the network into account and only say there's an error if there's an active network
connection _and_ `NSPersistentCloudKitContainer` says an import or export failed:

- `syncError`, which tells you that something has gone wrong when nothing should be going wrong
- `importError`, which tells you that the last import failed when it shouldn't have
- `exportError`, which tells you that the last export failed when it shouldn't have

Detecting these conditions is important because the usual "fix" for CloudKit not syncing is to delete the local database. This is fine if your
import stopped working, but if the export stopped working, this means that your user will lose any changes they made between the time the
sync failed and when it was detected. Previously, that time was based on when the user looked at two devices and noticed that they didn't
contain the same data. With `CloudKitSyncStatus`, your app can report (or act on) that failure _immediately_, saving your user's data and
your app's reputation.

# Installation

`CloudKitSyncStatus` is a swift package - add it to `Package.swift`:

    dependencies: [
        .package(url: "https://github.com/ggruen/CloudKitSyncStatus.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MyApp", // Where "MyApp" is the name of your app
            dependencies: ["SocketConnection"]),
    ]

Or, in Xcode, you can select File » Swift Packages » Add Package Dependency... and specify the repository URL
`https://github.com/ggruen/CloudKitSyncStatus.git` and "up to next major version" `1.0.0`.
