//
//  SyncEngine.swift
//  KitchenCore
//
//  Created by Guilherme Rambo on 24/02/20.
//  Copyright © 2020 Guilherme Rambo. All rights reserved.
//

import Foundation
import CloudKit
import os.log

public struct SyncConstants {

    public static let containerIdentifier = "iCloud.com.isapozhnik.CloudTest0"

    public static let subsystemName = "com.isapozhnik.CloudTest"

    public static let customZoneID: CKRecordZone.ID = {
        CKRecordZone.ID(zoneName: "CustomZone0", ownerName: CKCurrentUserDefaultName)
    }()
}

final class SyncEngine {
    private var typeRegistry: [String: any Syncable.Type] = [:]
    private var initializerRegistry: [String: (CKRecord) throws -> any Syncable] = [:]

    let log = OSLog(subsystem: SyncConstants.subsystemName, category: String(describing: SyncEngine.self))

    private let defaults: UserDefaults
    private let tokenManager: TokenManager
    private(set) var subscriptionManager: SubscriptionManager!
    private(set) var zoneManager: ZoneManager!

    private(set) lazy var container: CKContainer = {
        CKContainer(identifier: SyncConstants.containerIdentifier)
    }()

    private(set) lazy var privateDatabase: CKDatabase = {
        container.privateCloudDatabase
    }()

    private var buffer: [any Syncable]

    /// Called after models are updated with CloudKit data.
    var didUpdateModels: ([any Syncable]) -> Void = { _ in }

    /// Called when models are deleted remotely.
    var didDeleteModels: ([String]) -> Void = { _ in }

    init(
        defaults: UserDefaults,
        initialModels: [any Syncable]
    ) {
        self.defaults = defaults
        self.buffer = initialModels
        self.tokenManager = TokenManager(defaults: defaults)
    }
    
    func requestPermission() async throws -> Bool {
        try await container.accountStatus() == .available
    }

    private let workQueue = DispatchQueue(label: "SyncEngine.Work", qos: .userInitiated)
    private let cloudQueue = DispatchQueue(label: "SyncEngine.Cloud", qos: .userInitiated)

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
    
    func start() {
        prepareCloudEnvironment { [weak self] in
            guard let self else { return }

            os_log("Cloud environment preparation done", log: self.log, type: .debug)

            self.uploadLocalDataNotUploadedYet()
            self.fetchRemoteChanges()
        }
    }

    private lazy var cloudOperationQueue: OperationQueue = {
        let q = OperationQueue()

        q.underlyingQueue = cloudQueue
        q.name = "SyncEngine.Cloud"
        q.maxConcurrentOperationCount = 1

        return q
    }()

    private lazy var progress: Progress = {
        let p = Progress(totalUnitCount: 0)
        p.isCancellable = true
        p.isPausable = true
        return p
    }()

    var progressHandler: ((Double) -> Void)? = nil

    private func prepareCloudEnvironment(then block: @escaping () -> Void) {
        subscriptionManager = SubscriptionManager(
            queue: cloudOperationQueue,
            userDefaults: defaults,
            database: privateDatabase
        )
        
        zoneManager = ZoneManager(
            queue: cloudOperationQueue,
            userDefaults: defaults,
            database: privateDatabase
        )
        
        workQueue.async { [weak self] in
            guard let self else { return }

            guard zoneManager.createCustomZoneIfNeeded() else { return }

            let recordTypes = Array(Set(typeRegistry.keys))
            guard subscriptionManager.createPrivateSubscriptionsIfNeeded(recordTypes: recordTypes) else { return }

            DispatchQueue.main.async { block() }
        }
    }

    // MARK: - Upload

    private func uploadLocalDataNotUploadedYet() {
        os_log("%{public}@", log: log, type: .debug, #function)

        let models = buffer.filter { $0.ckData == nil }

        guard !models.isEmpty else { return }

        os_log("Found %d local model(s) which haven't been uploaded yet.", log: self.log, type: .debug, models.count)

        let records = models.map { $0.record }

        uploadRecords(records)
    }
    
    func upload(_ model: any Syncable) {
        os_log("%{public}@", log: log, type: .debug, #function)

        buffer.append(model)

        uploadRecords([model.record])
    }

    func delete(_ model: any Syncable) {
        os_log("%{public}@", log: log, type: .debug, #function)

        let recordID = CKRecord.ID(recordName: model.id, zoneID: SyncConstants.customZoneID)

        let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [recordID])

        operation.modifyRecordsCompletionBlock = { [weak self] _, deletedRecordIDs, error in
            guard let self else { return }

            if let error = error {
                os_log("Failed to delete record: %{public}@", log: self.log, type: .error, String(describing: error))
                error.retryCloudKitOperationIfPossible(self.log) { self.delete(model) }
            } else {
                os_log("Successfully deleted record", log: self.log, type: .info)
                DispatchQueue.main.async {
                    self.didDeleteModels([model.id])
                }
            }
        }

        operation.qualityOfService = .userInitiated
        operation.database = privateDatabase

        cloudOperationQueue.addOperation(operation)
    }

    private func uploadRecords(_ records: [CKRecord]) {
        guard !records.isEmpty else { return }

        progress.totalUnitCount += Int64(records.count)

        os_log("%{public}@ with %d record(s)", log: log, type: .debug, #function, records.count)
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        
        var serverRecords: [CKRecord] = []
        operation.perRecordSaveBlock = { [weak self] recordID, result in
            guard let self else { return }
            
            // We're only interested in conflict errors here
            guard
                case .failure(let error) = result,
                error.isCloudKitConflict.hasConflict,
                let conflictData = error.isCloudKitConflict.conflictData
            else {
                if case .success(let uploadedRecord) = result {
                    serverRecords.append(uploadedRecord)
                    progress.completedUnitCount += 1
                    DispatchQueue.main.async {
                        self.progressHandler?(Double(self.progress.fractionCompleted))
                    }
                }

                return
            }
            
            guard let syncableType = getType(for: conflictData.localRecord.recordType) else {
                os_log("No type registered for record type: %@", log: log, type: .error, conflictData.localRecord.recordType)
                uploadRecords([conflictData.localRecord])
                return
            }
            
            guard let resolvedRecord = error.resolveConflict(with: syncableType.resolveConflict) else {
                os_log(
                    "Resolving conflict with record of type %{public}@ returned a nil record. Giving up.",
                    log: self.log,
                    type: .error,
                    conflictData.localRecord.recordType
                )
                return
            }
            
            os_log("Conflict resolved, will retry upload", log: log, type: .info)
            
            self.uploadRecords([resolvedRecord])
        }
        
        operation.modifyRecordsResultBlock = { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                os_log("Failed to upload records: %{public}@", log: self.log, type: .error, String(describing: error))

                DispatchQueue.main.async {
                    self.handleUploadError(error, records: records)
                }
            case .success:
                os_log("Successfully uploaded %{public}d record(s)", log: self.log, type: .info, records.count)

                DispatchQueue.main.async {
                    self.updateLocalModelsAfterUpload(with: serverRecords)
                }
            }
        }

        operation.savePolicy = .allKeys
        operation.qualityOfService = .userInitiated
        
        // Add per-record progress tracking
        operation.perRecordProgressBlock = { record, progress in
            os_log("Progress for record %@: %.2f", log: self.log, type: .debug, record.recordID.recordName, progress)
        }
        
        // Set batch size for large operations
        operation.isAtomic = false
        operation.database = privateDatabase
        cloudOperationQueue.addOperation(operation)
    }

    private func handleUploadError(_ error: Error, records: [CKRecord]) {
        guard let ckError = error as? CKError else {
            os_log("Error was not a CKError, giving up: %{public}@", log: self.log, type: .fault, String(describing: error))
            return
        }

        if ckError.code == CKError.Code.limitExceeded {
            os_log("CloudKit batch limit exceeded, sending records in chunks", log: self.log, type: .error)

            fatalError("Not implemented: batch uploads. Here we should divide the records in chunks and upload in batches instead of trying everything at once.")
        } else {
            let result = error.retryCloudKitOperationIfPossible(self.log) { self.uploadRecords(records) }

            if !result {
                os_log("Error is not recoverable: %{public}@", log: self.log, type: .error, String(describing: error))
            }
        }
    }

    private func updateLocalModelsAfterUpload(with records: [CKRecord]) {
        let models: [any Syncable] = records.compactMap { (r: CKRecord) -> (any Syncable)? in
            guard var model = buffer.first(where: { $0.id == r.recordID.recordName }) else { return nil }

            model.ckData = r.encodedSystemFields
            buffer.removeAll(where: { $0.id == r.recordID.recordName })

            return model
        }

        DispatchQueue.main.async {
            guard models.isEmpty == false else { return }
            self.didUpdateModels(models)
//            self.buffer = []
        }
    }

    // MARK: - Remote change tracking

    func fetchRemoteChanges() {
        os_log("%{public}@", log: log, type: .debug, #function)

        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []

        let operation = CKFetchRecordZoneChangesOperation()
        operation.qualityOfService = .utility
        operation.database = privateDatabase
        
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: tokenManager.changeToken,
            resultsLimit: nil,
            desiredKeys: nil
        )

        operation.configurationsByRecordZoneID = [SyncConstants.customZoneID: config]
        operation.recordZoneIDs = [SyncConstants.customZoneID]
        operation.fetchAllChanges = true

        operation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, changeToken, _ in
            guard let self else { return }
            guard let changeToken else { return }

            tokenManager.changeToken = changeToken
        }
        
        operation.recordZoneFetchResultBlock = { [weak self] recordZoneID, result in
            guard let self else { return }
            switch result {
            case .success(let success):
                os_log("Commiting new change token", log: self.log, type: .debug)

                tokenManager.changeToken = success.serverChangeToken
            case .failure(let error):
                guard let error = error as? CKError else { return }
                os_log("Failed to fetch record zone changes: %{public}@",
                       log: self.log,
                       type: .error,
                       String(describing: error))

                if error.code == .changeTokenExpired {
                    os_log("Change token expired, resetting token and trying again", log: self.log, type: .error)

                    tokenManager.changeToken = nil

                    DispatchQueue.main.async { self.fetchRemoteChanges() }
                } else {
                    error.retryCloudKitOperationIfPossible(self.log) { self.fetchRemoteChanges() }
                }
            }
        }

        operation.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                if !changedRecords.contains(where: { $0.recordID == record.recordID }) {
                    changedRecords.append(record)
                }
            case .failure(let error):
                os_log("There was an error fetching a record: %{public}@",
                       log: self.log,
                       type: .error,
                       String(describing: error))
            }
        }

        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            // In the future we may need to use the second arg to this closure and map
            // between record types and deleted record IDs (when we need to sync more types)
            deletedRecordIDs.append(recordID)
        }

        operation.fetchRecordZoneChangesResultBlock = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                os_log("Finished fetching record zone changes", log: self.log, type: .info)

                DispatchQueue.main.async { self.commitServerChangesToDatabase(with: changedRecords, deletedRecordIDs: deletedRecordIDs) }
            case .failure(let error):
                os_log("Failed to fetch record zone changes: %{public}@",
                       log: self.log,
                       type: .error,
                       String(describing: error))

                error.retryCloudKitOperationIfPossible(self.log) { self.fetchRemoteChanges() }
            }
        }

        cloudOperationQueue.addOperation(operation)
    }

    private func commitServerChangesToDatabase(with changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID]) {
        guard !changedRecords.isEmpty || !deletedRecordIDs.isEmpty else {
            os_log("Finished record zone changes fetch with no changes", log: log, type: .info)
            return
        }

        os_log("Will commit %d changed record(s) and %d deleted record(s) to the database", log: log, type: .info, changedRecords.count, deletedRecordIDs.count)

        let newRecords = changedRecords.filter { record in
            !buffer.contains { model in 
                guard let modelCKData = model.ckData else { return false }
                return model.id == record["id"] &&
                       modelCKData == record.encodedSystemFields
            }
        }

        let models: [any Syncable] = newRecords.compactMap { record in
            do {
                return try createInstance(from: record)
            } catch {
                os_log("Error decoding model from record: %{public}@", log: self.log, type: .error, String(describing: error))
                return nil
            }
        }

        let deletedIdentifiers = deletedRecordIDs.map { $0.recordName }

        if !models.isEmpty {
            didUpdateModels(models)
        }
        if !deletedIdentifiers.isEmpty {
            didDeleteModels(deletedIdentifiers)
        }
    }

    /// Upload any Syncable type
    func uploadAny<T: Syncable>(_ model: T) {
        os_log("%{public}@", log: log, type: .debug, #function)
        uploadRecords([model.record])
    }
    
    func uploadAnys(_ models: [any Syncable]) {
        os_log("%{public}@", log: log, type: .debug, #function)
        buffer.append(contentsOf: models)
        uploadRecords(models.map { $0.record })
    }
    
    /// Delete any Syncable type
    func deleteAny<T: Syncable>(_ model: T) {
        os_log("%{public}@", log: log, type: .debug, #function)
        
        let recordID = CKRecord.ID(recordName: model.id, zoneID: SyncConstants.customZoneID)
        
        let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [recordID])
        
        operation.modifyRecordsCompletionBlock = { [weak self] _, _, error in
            guard let self else { return }
            
            if let error = error {
                os_log("Failed to delete record: %{public}@", log: self.log, type: .error, String(describing: error))
                error.retryCloudKitOperationIfPossible(self.log) { self.deleteAny(model) }
            } else {
                os_log("Successfully deleted record", log: self.log, type: .info)
                DispatchQueue.main.async {
                    self.didDeleteModels([model.id])
                }
            }
        }
        
        operation.qualityOfService = .userInitiated
        operation.database = privateDatabase
        
        cloudOperationQueue.addOperation(operation)
    }

}
