# SyncEngine

![SyncEngine logo](./Assets/image.webp)

# !!!Work in progress!!!

A Swift package that provides seamless CloudKit synchronization capabilities for your iOS and macOS applications. SyncEngine handles all the complexity of CloudKit sync, including conflict resolution, offline support, and automatic retries.

## Requirements
- iOS 13.0+ / macOS 12.0+
- Swift 5.9+
- CloudKit enabled in your application

## Features
- 🔄 Automatic synchronization with CloudKit
- 📱 Offline support with automatic sync when connection is restored
- 🔒 Private database support
- 🔍 Change tracking and conflict resolution
- 📦 Custom zone management
- 📡 Network status monitoring
- 👤 iCloud account status monitoring
- ⚡️ Efficient batch operations
- 🔄 Automatic retry mechanism for failed operations

## Installation

Add this package to your Xcode project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/iSapozhnik/SyncEngine.git", from: "1.0.0")
]
```

## Usage

### 1. Configure SyncEngine

First, create a configuration that implements `SyncEngineConfig`:

```swift
struct MySyncConfig: SyncEngineConfig {
    let containerIdentifier: String = "iCloud.com.yourapp.container"
    let zoneName: String = "YourZoneName"
    let ownerName: String? = nil // Uses current user by default
}
```

### 2. Make Your Models Syncable

Implement the `Syncable` protocol for any model you want to sync:

```swift
struct Note: Syncable {
    var ckData: Data? = nil
    let id: String
    let text: String
}

```

### 3. Initialize SyncEngine

```swift
let syncEngine = SyncEngine(
    syncConfig: MySyncConfig(),
    defaults: UserDefaults.standard,
    initialModels: [Note(text: "Hello, world!")]
)
// Handle model updates
syncEngine.didUpdateModels = { modelsByType in
// Update your local database with the changes
}
// Handle deletions
syncEngine.didDeleteModels = { recordIDs in
// Remove deleted records from your local database
}
```

### 4. Perform Sync

The SyncEngine will automatically sync when:
- The app becomes active
- Network connectivity is restored
- Manual sync is triggered

To manually trigger a sync:

```swift
do {
    try await syncEngine.performSync()
} catch {
    print("Sync failed: \(error)")
}
```

## Monitoring

### Account Status
```swift
// Observe account status changes
syncEngine.$accountStatus
    .sink { status in
        switch status {
        case .available:
            print("iCloud account is available")
        case .restricted:
            print("iCloud account is restricted")
        case .noAccount:
            print("No iCloud account")
        case .couldNotDetermine:
            print("Could not determine account status")
        default:
            break
        }
    }
    .store(in: &cancellables)
```

### Network Status
```swift
// Observe network availability
syncEngine.$isNetworkAvailable
    .sink { isAvailable in
        if isAvailable == true {
            print("Network is available")
        } else {
            print("Network is unavailable")
        }
    }
    .store(in: &cancellables)
```

### Sync State
```swift
// Observe sync state changes
syncEngine.$state
    .sink { state in
        switch state {
        case .idle:
            print("Sync is idle")
        case .loading:
            print("Sync is in progress")
        }
    }
    .store(in: &cancellables)
```

## Progress Tracking

```swift
syncEngine.progressHandler = { progress in
    print("Sync progress: \(progress * 100)%")
}
```

## Best Practices

1. **Error Handling**: Always implement proper error handling for sync operations
   ```swift
   do {
       try await syncEngine.performSync()
   } catch {
       if let cloudError = error as? CKError {
           // Handle specific CloudKit errors
       }
       // Handle other errors
   }
   ```

2. **Conflict Resolution**: Implement proper conflict resolution in your Syncable models
   ```swift
   static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
       // Example: Server wins strategy
       return serverRecord
       
       // Or implement custom merge logic
       // let mergedRecord = serverRecord
       // mergedRecord["field"] = determineWinningValue(client: clientRecord, server: serverRecord)
       // return mergedRecord
   }
   ```

3. **Data Consistency**: Keep local cache in sync with remote changes
   ```swift
   syncEngine.didUpdateModels = { modelsByType in
       // Update local database
       for (type, models) in modelsByType {
           database.update(models)
       }
   }
   
   syncEngine.didDeleteModels = { recordIDs in
       // Remove from local database
       database.delete(recordIDs)
   }
   ```

4. **Resource Management**: Stop monitoring when appropriate
   ```swift
   // In your cleanup code
   syncEngine.stopMonitoring()
   ```

## Limitations

- Requires iOS 13.0+ or macOS 12.0+
- Only supports private database operations
- Requires active iCloud account
- Network connectivity required for sync operations (though offline changes are queued)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

[Your license information here]