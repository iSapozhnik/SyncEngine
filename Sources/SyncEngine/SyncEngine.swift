import Foundation
import CloudKit
import os.log
import Combine

public enum SyncState {
    case idle
    case loading
}

final class SyncEngine {
    enum Constants {
        static let retryCount: Int = 3
        static let subsystemName = "com.isapozhnik.SyncEngine"
        static let environmentCheckInterval: TimeInterval = 15 * 60
    }
    enum EngineError: Error {
        case setupFailed
        case failedFetchingRemoteChanges
        case uploaded
    }
    var typeRegistry: [String: any Syncable.Type] = [:]
    var initializerRegistry: [String: (CKRecord) throws -> any Syncable] = [:]

    @MainActor
    private let continuation: AsyncStream<SyncState>.Continuation
    var lastState: SyncState = .idle {
        didSet {
            guard lastState != oldValue else { return }
            continuation.yield(lastState)
        }
    }
    private var isFetching = false
    
    let syncState: AsyncStream<SyncState>
    @Published public private(set) var state: SyncState = .idle
    
    let log = OSLog(subsystem: Constants.subsystemName, category: String(describing: SyncEngine.self))
    let taskSerializer = SerialTasks<Void>()

    private let defaults: UserDefaults
    private let tokenManager: TokenManager
    
    let accountMiddleware: AccountStatusMiddleware
    @Published public private(set) var accountStatus: CKAccountStatus? = nil
    private var accountStatusTask: Task<Void, Never>?

    let networkMiddleware: NetworkStatusMiddleware
    @Published public private(set) var isNetworkAvailable: Bool? = nil
    private var networkStatusTask: Task<Void, Never>?
    
    private var monitoringTask: Task<Void, Error>?

    let subscriptionManager: SubscriptionManager
    private let zoneManager: ZoneManager

    private let container: CKContainer
    let config: SyncEngineConfig

    private(set) lazy var privateDatabase: CKDatabase = {
        container.privateCloudDatabase
    }()

    var buffer: [any Syncable]

    /// Called after models are updated with CloudKit data.
    var didUpdateModels: ([String: [any Syncable]]) -> Void = { _ in }

    /// Called when models are deleted remotely.
    var didDeleteModels: ([String]) -> Void = { _ in }

    var progressHandler: ((Double) -> Void)? = nil

    let pendingOperationsManager = PendingOperationsManager()

    let applicationMiddleware: ApplicationStateMiddleware
    @Published public private(set) var isApplicationActive: Bool? = nil
    private var applicationStateTask: Task<Void, Never>?
    private var lastEnvironmentUpdate: Date?

    init(
        syncConfig: SyncEngineConfig,
        defaults: UserDefaults,
        initialModels: [any Syncable]
    ) {
        self.defaults = defaults
        self.buffer = initialModels
        self.tokenManager = TokenManager(
            syncConfig: syncConfig,
            defaults: defaults
        )
        config = syncConfig
        container = CKContainer(identifier: config.containerIdentifier)
        accountMiddleware = AccountStatusMiddleware(container: container)
        networkMiddleware = NetworkStatusMiddleware()
        
        subscriptionManager = SubscriptionManager(
            syncConfig: config,
            userDefaults: defaults,
            database: container.privateCloudDatabase
        )
        
        zoneManager = ZoneManager(
            syncConfig: config,
            userDefaults: defaults,
            database: container.privateCloudDatabase
        )

        (syncState, continuation) = AsyncStream<SyncState>.makeStream()
        
        applicationMiddleware = ApplicationStateMiddleware()
        
        startMonitoring()
    }

    deinit {
        networkStatusTask?.cancel()
    }

    // MARK: - Setup boilerplate
    
    func performSync() async throws {
        
        guard try await syncConditionsMet() else { return }
        
        lastState = .loading
        
        defer {
            lastState = .idle
        }
        
        guard try await prepareCloudEnvironment() else {
            throw EngineError.setupFailed
        }
                
        do {
            try await processPendingDeletions()
            try await uploadLocalDataNotUploadedYet()
            try await fetchRemoteChanges()
        } catch {
            os_log("❌ Sync failed: %{public}@", log: log, type: .error, error.localizedDescription)
            throw error
        }
    }
    
    func stopMonitoring() {
        networkMiddleware.stopMonitoring()
        monitoringTask?.cancel()
    }
    
    private func prepareCloudEnvironment() async throws -> Bool {
        func prepareEnvironment() async throws -> Bool {
            async let zoneCreation = zoneManager.createCustomZoneIfNeeded()
            let recordTypes = typeRegistry.uniqueKeys
            async let subscriptionCreation = subscriptionManager.createPrivateSubscriptionsIfNeeded(recordTypes: recordTypes)
            
            let zoneCreated = try await zoneCreation
            let subscriptionCreated = try await subscriptionCreation
            lastEnvironmentUpdate = .now

            os_log("✅ Cloud environment preparation done", log: self.log, type: .debug)

            return zoneCreated && subscriptionCreated
        }
        
        guard let lastEnvironmentUpdate else {
            os_log("No previous environment setup found, preparing environment", log: log, type: .debug)
            return try await prepareEnvironment()
        }
        
        let timeSinceLastUpdate = Date.now.timeIntervalSince(lastEnvironmentUpdate)
        if timeSinceLastUpdate > Constants.environmentCheckInterval {
            os_log("Environment check interval exceeded (%{public}d minutes), preparing environment",
                   log: log,
                   type: .debug,
                   Int(timeSinceLastUpdate/60))
            return try await prepareEnvironment()
        }
        
        os_log("Environment was recently checked (%{public}d minutes ago), skipping preparation",
               log: log,
               type: .debug,
               Int(timeSinceLastUpdate/60))
        return true
    }
    
    private func startMonitoring() {
        monitoringTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.monitorNetworkStatus() }
                group.addTask { await self.monitorAccountStatus() }
                group.addTask { await self.monitorSyncState() }
                group.addTask { await self.monitorApplicationState() }
                await group.waitForAll()
            }
        }
    }
    
    private func monitorSyncState() async {
        for await state in syncState {
            guard !Task.isCancelled else { break }
            switch state {
            case .loading:
                os_log("🔄 Sync in progress...", log: log, type: .debug)
            case .idle:
                os_log("🔄 Sync completed!", log: log, type: .debug)
            }

            self.state = state
        }
    }
    
    private func monitorAccountStatus() async {
        for await accountStatus in accountMiddleware.accountStatus {
            guard !Task.isCancelled else { break }
            self.accountStatus = accountStatus
        }
    }
    
    private func monitorNetworkStatus() async {
        isNetworkAvailable = networkMiddleware.isNetworkAvailable
        for await isAvailable in networkMiddleware.networkPathUpdates() {
            guard !Task.isCancelled else { break }
            isNetworkAvailable = isAvailable
            if isAvailable {
                os_log("🌐 Network became available - attempting sync", log: log, type: .debug)
                do {
                    try await taskSerializer.add {
                        try await self.performSync()
                    }
                } catch {
                    os_log("❌ Failed to sync when network became available: %{public}@",
                           log: log, type: .error, error.localizedDescription)
                }
            } else {
                os_log("🌐 Network became unavailable", log: log, type: .debug)
            }
        }
    }
    
    private func monitorApplicationState() async {
        isApplicationActive = applicationMiddleware.isActive
        for await state in applicationMiddleware.applicationState {
            guard !Task.isCancelled else { break }
            let isActive = state == .active
            isApplicationActive = isActive
            
            if isActive {
                os_log("📱 App became active - attempting sync", log: log, type: .debug)
                do {
                    try await taskSerializer.add {
                        try await self.performSync()
                    }
                } catch {
                    os_log("❌ Failed to sync when app became active: %{public}@",
                           log: log, type: .error, error.localizedDescription)
                }
            } else {
                os_log("📱 App resigned active", log: log, type: .debug)
            }
        }
    }
    
    // MARK: - Remote change tracking
    
    func fetchRemoteChanges(retryCount: Int = Constants.retryCount) async throws {
        defer {
            lastState = .idle
            isFetching = false
        }
        guard try await syncConditionsMet() else { return }
        guard isFetching == false else { return }
        isFetching = true

        guard retryCount > 0 else {
            throw EngineError.failedFetchingRemoteChanges
        }
        
        os_log("%{public}@", log: log, type: .debug, #function)
        
        lastState = .loading
        
        var awaitingChanges = true
        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        
        do {
            while awaitingChanges {
                let allChanges = try await privateDatabase.recordZoneChanges(
                    inZoneWith: config.customZoneID,
                    since: tokenManager.changeToken
                )
                
                let changes = allChanges.modificationResultsByID.compactMapValues { try? $0.get().record }
                for (_, record) in changes {
                    changedRecords.append(record)
                }
                
                let deletetions = allChanges.deletions.map { $0.recordID }
                deletedRecordIDs.append(contentsOf: deletetions)
                
                tokenManager.changeToken = allChanges.changeToken
                
                awaitingChanges = allChanges.moreComing
            }
            
        } catch {
            os_log("Failed to fetch record zone changes: %{public}@",
                   log: self.log,
                   type: .error,
                   String(describing: error))

            if (error as? CKError)?.code == .changeTokenExpired {
                os_log("Change token expired, resetting token and trying again", log: self.log, type: .error)

                tokenManager.changeToken = nil
                try await fetchRemoteChanges()
            } else {
                if await error.retryCloudKitOperationIfPossible(log) {
                    try await fetchRemoteChanges(retryCount: retryCount - 1)
                } else {
                    lastState = .idle
                    throw error
                }
            }
        }
        
        let groupedChangedRecords = Dictionary(grouping: changedRecords, by: \.recordType)
        await commitServerChangesToDatabase(with: groupedChangedRecords, deletedRecordIDs: deletedRecordIDs)
    }
    
    private func commitServerChangesToDatabase(with changedRecords: [String: [CKRecord]], deletedRecordIDs: [CKRecord.ID]) async {
        let allChangedRecords = Array(changedRecords.values.flatMap(\.self))
        guard !allChangedRecords.isEmpty || !deletedRecordIDs.isEmpty else {
            os_log("✅ Finished record zone changes fetch with no changes", log: log, type: .info)
            return
        }
        
        os_log("Will commit %d changed record(s) and %d deleted record(s) to the database", log: log, type: .info, allChangedRecords.count, deletedRecordIDs.count)

        let newRecords: [CKRecord] = allChangedRecords.filter { record in
            !buffer.contains { model in
                guard let modelCKData = model.ckData else { return false }
                return model.id == record["id"] && modelCKData == record.encodedSystemFields
            }
        }
        
        let models = newRecords.compactMap { (record) -> (recordType: String, model: any Syncable)? in
            do {
                if let instance = try createInstance(from: record) {
                    return (recordType: record.recordType, model: instance)
                } else {
                    return nil
                }
            } catch {
                os_log("Error decoding model from record: %{public}@", log: self.log, type: .error, String(describing: error))
                return nil
            }
        }
        
        var convertedModels: [String: [any Syncable]] = [:]
        let groupedModels = Dictionary(
            grouping: models,
            by: { $0.recordType }
        )
        for (key, value) in groupedModels {
            let models: [any Syncable] = value.map { $0.model }
            convertedModels[key] = models
        }

        let deletedIdentifiers = deletedRecordIDs.map { $0.recordName }
        
        await MainActor.run { [convertedModels] in
            if !convertedModels.isEmpty {
                self.didUpdateModels(convertedModels)
            }
            if !deletedIdentifiers.isEmpty {
                self.didDeleteModels(deletedIdentifiers)
            }
        }
    }

    func processPendingDeletions() async throws {
        let pendingDeletions = pendingOperationsManager.getPendingDeletions()
        guard !pendingDeletions.isEmpty else { return }
        
        os_log("Processing %d pending deletions", log: log, type: .debug, pendingDeletions.count)
        
        do {
            let deletedRecordIDs = try await delete(pendingDeletions)
            pendingOperationsManager.removePendingDeletions(recordIDs: deletedRecordIDs.map(\.recordName))
        } catch {
            os_log("Failed to process pending deletions: %{public}@",
                   log: log, type: .error, error.localizedDescription)
        }
    }
}

extension Dictionary<String, any Syncable.Type> {
    var uniqueKeys: [Key] {
        Array(Set(self.keys))
    }
}
