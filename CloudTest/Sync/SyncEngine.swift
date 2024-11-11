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
    let taskTracker = SyncTaskTracker()

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

    var progressHandler: ((Double) -> Void)? = nil

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
    
    func start() async throws {
        try await prepareCloudEnvironment()
        os_log("Cloud environment preparation done", log: self.log, type: .debug)
        
        await uploadLocalDataNotUploadedYet()
        try await fetchRemoteChanges()
    }
    
    private func prepareCloudEnvironment() async throws {
        subscriptionManager = SubscriptionManager(
            userDefaults: defaults,
            database: privateDatabase
        )
        
        zoneManager = ZoneManager(
            queue: .main,
            userDefaults: defaults,
            database: privateDatabase
        )
        
//        guard try await zoneManager.createCustomZoneIfNeeded() else {
//            throw NSError(domain: "SyncEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create custom zone"])
//        }
        
        let recordTypes = Array(Set(typeRegistry.keys))
        guard try await subscriptionManager.createPrivateSubscriptionsIfNeeded(recordTypes: recordTypes) else {
            throw NSError(domain: "SyncEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create subscriptions"])
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
        
        let recordID = CKRecord.ID(recordName: model.id, zoneID: SyncConstants.customZoneID)
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
        
        var serverRecords: [CKRecord] = []
        
        try await withThrowingTaskGroup(of: CKRecord.self) { group in
            for record in records {
                group.addTask {
                    do {
                        let savedRecord = try await self.privateDatabase.save(record)
                        progress.completedUnitCount += 1
                        await MainActor.run {
                            self.progressHandler?(Double(progress.fractionCompleted))
                        }
                        return savedRecord
                    } catch let error as CKError {
                        if error.isCloudKitConflict.hasConflict,
                           let conflictData = error.isCloudKitConflict.conflictData {
                            guard let syncableType = self.getType(for: conflictData.localRecord.recordType) else {
                                throw error
                            }
                            
                            let resolvedRecord = syncableType.resolveConflict(
                                clientRecord: conflictData.localRecord,
                                serverRecord: conflictData.remoteRecord
                            )
                            
                            return try await self.privateDatabase.save(resolvedRecord)
                        }
                        throw error
                    }
                }
            }
            
            for try await record in group {
                serverRecords.append(record)
            }
        }
        
        await updateLocalModelsAfterUpload(with: serverRecords)
    }
    
    private func updateLocalModelsAfterUpload(with records: [CKRecord]) async {
        let models: [any Syncable] = records.compactMap { (r: CKRecord) -> (any Syncable)? in
            guard var model = buffer.first(where: { $0.id == r.recordID.recordName }) else { return nil }
            
            model.ckData = r.encodedSystemFields
            buffer.removeAll(where: { $0.id == r.recordID.recordName })
            
            return model
        }
        
        await MainActor.run {
            guard !models.isEmpty else { return }
            self.didUpdateModels(models)
        }
    }
    
    // MARK: - Remote change tracking
    
    func fetchRemoteChanges() async throws {
        os_log("%{public}@", log: log, type: .debug, #function)
        
        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: tokenManager.changeToken,
            resultsLimit: nil,
            desiredKeys: nil
        )
        
        let allChanges = try await privateDatabase.recordZoneChanges(
            inZoneWith: SyncConstants.customZoneID,
            since: tokenManager.changeToken
        )
        
        tokenManager.changeToken = allChanges.changeToken
        let changes = allChanges.modificationResultsByID.compactMapValues { try? $0.get().record }
        for (_, record) in changes {
            changedRecords.append(record)
        }
        
        deletedRecordIDs = allChanges.deletions.map { $0.recordID }
        
        await commitServerChangesToDatabase(with: changedRecords, deletedRecordIDs: deletedRecordIDs)
    }
    
    private func commitServerChangesToDatabase(with changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID]) async {
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
        
        await MainActor.run {
            if !models.isEmpty {
                self.didUpdateModels(models)
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
        buffer.append(contentsOf: models)
        try await uploadRecords(models.map { $0.record })
    }
    
    func deleteAny<T: Syncable>(_ model: T) async throws {
        os_log("%{public}@", log: log, type: .debug, #function)
        try await delete(model)
    }
}
