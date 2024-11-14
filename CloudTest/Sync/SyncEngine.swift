import Foundation
import CloudKit
import os.log

public enum SyncState {
    case idle
    case loading
}

final class SyncEngine {
    enum Constants {
        static let retryCount: Int = 3
        static let subsystemName = "com.isapozhnik.SyncEngine"
    }
    enum EngineError: Error {
        case setupFailed
        case failedFetchingRemoteChanges
        case noNetworkConnection
        case noICloudAccount
    }
    private var typeRegistry: [String: any Syncable.Type] = [:]
    private var initializerRegistry: [String: (CKRecord) throws -> any Syncable] = [:]

    @MainActor
    private let continuation: AsyncStream<SyncState>.Continuation
    private var lastState: SyncState = .idle {
        didSet {
            guard lastState != oldValue else { return }
            continuation.yield(lastState)
        }
    }
    private var isFetching = false
    
    let syncState: AsyncStream<SyncState>
    
    let log = OSLog(subsystem: Constants.subsystemName, category: String(describing: SyncEngine.self))
    let taskSerializer = SerialTasks<Void>()

    private let defaults: UserDefaults
    private let tokenManager: TokenManager
    private let accountMiddleware: AccountStatusMiddleware
    private let networkMiddleware: NetworkStatusMiddleware
    var networkStatus: AsyncStream<Bool> { networkMiddleware.networkStatus }

    private(set) var subscriptionManager: SubscriptionManager!
    private(set) var zoneManager: ZoneManager!
    private var statusTask: Task<Void, Never>?

    private let container: CKContainer
    private let config: SyncEngineConfig

    private(set) lazy var privateDatabase: CKDatabase = {
        container.privateCloudDatabase
    }()

    private var buffer: [any Syncable]

    /// Called after models are updated with CloudKit data.
    var didUpdateModels: ([String: [any Syncable]]) -> Void = { _ in }

    /// Called when models are deleted remotely.
    var didDeleteModels: ([String]) -> Void = { _ in }

    var progressHandler: ((Double) -> Void)? = nil

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

        (syncState, continuation) = AsyncStream<SyncState>.makeStream()
        
        setupAccountStatusMonitoring()
        setupNetworkStatusMonitoring()
    }
    
    func requestPermission() async throws -> Bool {
        await accountMiddleware.refreshStatus()
        return accountMiddleware.lastKnownStatus == .available
    }

    // MARK: - Setup boilerplate
    
    func register<T: Syncable>(_ type: T.Type) {
        typeRegistry[T.recordType] = type
        initializerRegistry[T.recordType] = { record in
            try T(record: record, configure: nil)
        }
    }
    
    private func getType(for recordType: String) -> (any Syncable.Type)? {
        return typeRegistry[recordType]
    }
    
    private func createInstance(from record: CKRecord) throws -> (any Syncable)? {
        guard let initializer = initializerRegistry[record.recordType] else { return nil }
        return try initializer(record)
    }
    
    func performSync() async throws {
        guard networkMiddleware.isNetworkAvailable else {
            os_log("❌ Cannot start sync - no network connection", log: log, type: .error)
            throw EngineError.noNetworkConnection
        }
        
        guard try await requestPermission() else {
            os_log("❌ Cannot start sync - no iCloud account", log: log, type: .error)
            throw EngineError.noICloudAccount
        }
        
        lastState = .loading
        
        defer {
            lastState = .idle
        }
        
        guard try await prepareCloudEnvironment() else {
            throw EngineError.setupFailed
        }
        
        os_log("✅ Cloud environment preparation done", log: self.log, type: .debug)
        
        do {
            await uploadLocalDataNotUploadedYet()
            try await fetchRemoteChanges()
        } catch {
            os_log("❌ Sync failed: %{public}@", log: log, type: .error, error.localizedDescription)
            throw error
        }
    }
    
    func stopMonitoring() {
        networkMiddleware.stopMonitoring()
    }
    
    private func prepareCloudEnvironment() async throws -> Bool {
        subscriptionManager = SubscriptionManager(
            syncConfig: config,
            userDefaults: defaults,
            database: privateDatabase
        )
        
        zoneManager = ZoneManager(
            syncConfig: config,
            userDefaults: defaults,
            database: privateDatabase
        )
        
        async let zoneCreation = zoneManager.createCustomZoneIfNeeded()
        let recordTypes = Array(Set(typeRegistry.keys))
        async let subscriptionCreation = subscriptionManager.createPrivateSubscriptionsIfNeeded(recordTypes: recordTypes)
        
        let zoneCreated = try await zoneCreation
        let subscriptionCreated  = try await subscriptionCreation
        return zoneCreated && subscriptionCreated
    }
    
    private func setupAccountStatusMonitoring() {
        statusTask = Task {
            for await status in accountMiddleware.accountStatus {
                await MainActor.run {
                    os_log("☁️ iCloud account status: %{public}@", log: log, type: .info, "\(status.description). \(status.detailedDescription)")
                }
            }
        }
    }
    
    private func setupNetworkStatusMonitoring() {
        networkMiddleware.startMonitoring()
        
        Task {
            for await isNetworkAvailable in networkMiddleware.networkStatus {
                if isNetworkAvailable {
                    os_log("🌐 Network became available - attempting sync", log: log, type: .debug)
                    // Only sync if we have an active iCloud account
                    if accountMiddleware.lastKnownStatus == .available {
                        do {
                            try await fetchRemoteChanges()
                            await uploadLocalDataNotUploadedYet()
                        } catch {
                            os_log("❌ Failed to sync when network became available: %{public}@", 
                                  log: log, 
                                  type: .error, 
                                  error.localizedDescription)
                        }
                    }
                } else {
                    os_log("🌐 Network became unavailable", log: log, type: .debug)
                }
            }
        }
    }
    
    // MARK: - Upload
    
    private func uploadLocalDataNotUploadedYet() async {
        os_log("%{public}@", log: log, type: .debug, #function)
        
        let models = buffer.filter { $0.ckData == nil }
        guard !models.isEmpty else { return }
        
        os_log("Found %d local model(s) which haven't been uploaded yet.", log: self.log, type: .debug, models.count)
        
        let records = models.map { $0.record }
        try? await uploadRecords(records)
    }
    
    func upload(_ model: any Syncable) async throws {
        os_log("%{public}@", log: log, type: .debug, #function)
        buffer.append(model)
        try await uploadRecords([model.record])
    }
    
    func delete(_ model: any Syncable) async throws {
        os_log("%{public}@", log: log, type: .debug, #function)
        
        let recordID = CKRecord.ID(recordName: model.id, zoneID: config.customZoneID)
        try await privateDatabase.deleteRecord(withID: recordID)
        
        await MainActor.run {
            self.didDeleteModels([model.id])
        }
    }
    
    private func uploadRecords(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        
        let progress = Progress(totalUnitCount: Int64(records.count))
        progress.isCancellable = true
        progress.isPausable = true
        
        os_log("%{public}@ with %d record(s)", log: log, type: .debug, #function, records.count)
        
        let modifyResult = try await privateDatabase.modifyRecords(
            saving: records,
            deleting: []
        )
        
        var serverRecords: [CKRecord] = []
        
        for (recordID, result) in modifyResult.saveResults {
            do {
                let savedRecord = try result.get()
                progress.completedUnitCount += 1

                await MainActor.run {
                    self.progressHandler?(Double(progress.fractionCompleted))
                }
                serverRecords.append(savedRecord)
            } catch let error as CKError {
                if error.isCloudKitConflict.hasConflict, let conflictData = error.isCloudKitConflict.conflictData {
                    guard let syncableType = getType(for: conflictData.localRecord.recordType) else {
                        throw error
                    }
                    
                    let resolvedRecord = syncableType.resolveConflict(
                        clientRecord: conflictData.localRecord,
                        serverRecord: conflictData.remoteRecord
                    )
                    
                    // Handle the resolved conflict by saving it
                    let conflictResult = try await privateDatabase.modifyRecords(
                        saving: [resolvedRecord],
                        deleting: [],
                        savePolicy: .changedKeys
                    )
                    if let savedRecord = try conflictResult.saveResults[recordID]?.get() {
                        await MainActor.run {
                            self.progressHandler?(Double(progress.fractionCompleted))
                        }
                        serverRecords.append(savedRecord)
                    }
                } else {
                    throw error
                }
            }
        }
        let groupedServerRecords: [String: [CKRecord]] = Dictionary(grouping: serverRecords, by: \.recordType)
        await updateLocalModelsAfterUpload(with: groupedServerRecords)
    }
    
    private func updateLocalModelsAfterUpload(with records: [String: [CKRecord]]) async {
        var convertedModels: [String: [any Syncable]] = [:]
        for (key, records) in records {
            let models = records.compactMap { (record: CKRecord) -> (any Syncable)? in
                guard var model = buffer.first(where: { $0.id == record.recordID.recordName }) else { return nil }
                model.ckData = record.encodedSystemFields
                buffer.removeAll(where: { $0.id == record.recordID.recordName })
                return model
            }
            convertedModels[key] = models
        }
        
        guard !convertedModels.isEmpty else { return }
        await MainActor.run { [convertedModels] in
            self.didUpdateModels(convertedModels)
        }
    }
    
    // MARK: - Remote change tracking
    
    func fetchRemoteChanges(retryCount: Int = Constants.retryCount) async throws {
        defer {
            lastState = .idle
            isFetching = false
        }
        
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
    
    // MARK: - Convenience Methods
    
    func uploadAny<T: Syncable>(_ model: T) async throws {
        os_log("%{public}@", log: log, type: .debug, #function)
        try await uploadRecords([model.record])
    }
    
    func uploadAnys(_ models: [any Syncable]) async throws {
        os_log("%{public}@", log: log, type: .debug, #function)
        lastState = .loading
        buffer.append(contentsOf: models)
        try await uploadRecords(models.map { $0.record })
        lastState = .idle
    }
    
    func deleteAny<T: Syncable>(_ model: T) async throws {
        os_log("%{public}@", log: log, type: .debug, #function)
        try await delete(model)
    }
}
