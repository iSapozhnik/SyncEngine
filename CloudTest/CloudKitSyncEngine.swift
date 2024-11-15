//
//  CloudKitSyncEngine.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 05.11.24.
//

import Foundation
import CloudKit
import CoreData
import os.log

enum CloudKitError: LocalizedError {
    case itemNotValid
    case itemNotFound
    
    var errorDescription: String? {
        switch self {
        case .itemNotValid: return "Clipboard item does not have ID"
        case .itemNotFound: return "Clipboard item not found in CoreData"
        }
    }
}

class CloudKitSyncEngine {
    static let shared = CloudKitSyncEngine()
    private let zone = CKRecordZone(zoneName: "CustomZone")
    private let container: CKContainer
    private let database: CKDatabase
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CloudKitSyncEngine", category: "CloudKit")
    let log = OSLog(subsystem: SyncConstants.subsystemName, category: String(describing: CloudKitSyncEngine.self))

    
    private var syncToken: CKServerChangeToken? {
        get {
            let data = UserDefaults.standard.data(forKey: "cloudKitSyncToken")
            return data.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        }
        set {
            guard let token = newValue,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
                UserDefaults.standard.removeObject(forKey: "cloudKitSyncToken")
                return
            }
            UserDefaults.standard.set(data, forKey: "cloudKitSyncToken")
        }
    }
    
    private init() {
        container = CKContainer(identifier: "iCloud.com.isapozhnik.CloudTest")
        database = container.privateCloudDatabase
        container.accountStatus { [weak self] status, error in
            guard let self else { return }
            
            if let error = error {
                logger.error("CloudKit account status error: \(error.localizedDescription)")
                return
            }
            
            switch status {
            case .available:
                logger.info("CloudKit is available")
                createCustomZoneIfNeeded()
            case .noAccount:
                logger.error("No iCloud account")
            case .restricted:
                logger.error("iCloud is restricted")
            case .couldNotDetermine:
                logger.error("Could not determine iCloud status")
            case .temporarilyUnavailable:
                logger.error("ClouKit is temporary unavailable")
            @unknown default:
                logger.error("Unknown iCloud status")
            }
        }
    }
    
    private func createCustomZoneIfNeeded() {
        // Avoid the operation if this has already been done.
        guard !UserDefaults.standard.bool(forKey: "isZoneCreated") else {
            return
        }
        Task {
            do {
                _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            } catch {
                print("ERROR: Failed to create custom zone: \(error.localizedDescription)")
            }
        }
        
        UserDefaults.standard.setValue(true, forKey: "isZoneCreated")
    }
    
    func requestPermission() async throws -> Bool {
        try await container.accountStatus() == .available
    }
    
    func save(_ clipboardItem: ClipboardItem) async throws {
        do {
            // Save the main ClipboardItem record
            let itemRecord = try createClipboardItemRecord(from: clipboardItem)
            let savedItemRecord = try await database.save(itemRecord)
            
            // Fetch and save all related content records
            let contentRecords = try await fetchContentRecords(for: clipboardItem)
            let savedContentRecords = try await withThrowingTaskGroup(of: CKRecord.self) { group in
                for record in contentRecords {
                    group.addTask {
                        try await self.database.save(record)
                    }
                }
                
                var savedRecords: [CKRecord] = []
                for try await record in group {
                    savedRecords.append(record)
                }
                return savedRecords
            }
            
            // Update local records with CloudKit information
            try await updateLocalRecords(clipboardItem: clipboardItem, 
                                       itemRecord: savedItemRecord, 
                                       contentRecords: savedContentRecords)
        } catch let error as CKError {
            logger.error("Error saving record: \(error.localizedDescription)")
            switch error.code {
            case .serverRecordChanged:
                if let serverRecord = error.serverRecord {
                    // Handle conflict
                    let resolvedRecord = resolveConflict(
                        clientRecord: try createClipboardItemRecord(from: clipboardItem),
                        serverRecord: serverRecord
                    )
                    try await database.save(resolvedRecord)
                }
            default:
                throw error
            }
        }
    }
    
    func performSync() async throws {
        try await fetchCloudChanges()
        try await uploadLocalChanges()
    }
    
    func deleteItem(_ item: ClipboardItemMO) async throws {
        guard let recordID = item.cloudKitRecordID.map({ CKRecord.ID(recordName: $0) }) else { return }
        try await database.deleteRecord(withID: recordID)
    }
    
    // MARK: - Private
    
    private func createClipboardItemRecord(from item: ClipboardItem) throws -> CKRecord {
        let zoneID = CKRecordZone(zoneName: "CustomZone").zoneID
        let recordID = item.cloudKitRecordID.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        ?? CKRecord.ID(recordName: item.id, zoneID: zoneID)
        let record = CKRecord(recordType: "ClipboardItem", recordID: recordID)
        
        record["id"] = item.id
        record["timestamp"] = item.timestamp
//        record["modificationDate"] = item.modificationDate
    
        
        return record
    }
    
    private func createContentRecord(from content: ClipboardItemContent) throws -> CKRecord {
//        guard let contentID = content.id else {
//            throw CloudKitError.itemNotValid
//        }
        let zoneID = CKRecordZone(zoneName: "CustomZone").zoneID

        let recordID = content.cloudKitRecordID.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        ?? CKRecord.ID(recordName: content.id, zoneID: zoneID)
        let record = CKRecord(recordType: "ClipboardItemContent", recordID: recordID)
        
        record["id"] = content.id
        record["clipboardItemId"] = content.clipboardItemId
        record["timestamp"] = content.timestamp
//        record["modificationDate"] = content.modificationDate
//        record["isRemoved"] = content.isRemoved
        record["typeIdentifier"] = content.typeIdentifier
        
        // Handle large data using CKAsset if needed
        if content.data.count > 1_000_000 {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try content.data.write(to: tempURL)
            let asset = CKAsset(fileURL: tempURL)
            record["data"] = asset
        } else {
            record["data"] = content.data
        }
        
        return record
    }
    
    private func fetchContentRecords(for item: ClipboardItem) async throws -> [CKRecord] {
        return try item.contents.map { try createContentRecord(from: $0) }
    }
    
    private func updateLocalRecords(clipboardItem: ClipboardItem, 
                                  itemRecord: CKRecord, 
                                  contentRecords: [CKRecord]) async throws {
        try await CoreDataManager.shared.updateCloudKitRecords(
            for: clipboardItem,
            itemRecord: itemRecord,
            contentRecords: contentRecords
        )
    }
    
    private func fetchCloudChanges() async throws {
        var changesToken = syncToken
        var hasMoreChanges = true
        
        while hasMoreChanges {
            let (changeToken, records, moreComing) = try await fetchNextBatch(since: changesToken)
            try await processFetchedRecords(records)
            changesToken = changeToken
            hasMoreChanges = moreComing
        }
        
        syncToken = changesToken
    }
    
    private func fetchNextBatch(since token: CKServerChangeToken?) async throws -> (CKServerChangeToken?, [CKRecord], Bool) {
        let zoneID = CKRecordZone(zoneName: "CustomZone").zoneID

        let allChanges = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
        let changes = allChanges.modificationResultsByID.compactMapValues { try? $0.get().record }
        var records: [CKRecord] = []
        changes.forEach { _, record in
            records.append(record)
        }
        let deletetions = allChanges.deletions.map { $0.recordID }
        for deletion in deletetions {
            try await handleDeletedRecord(deletion)
        }
        
        return (allChanges.changeToken, records, allChanges.moreComing)
    }
    
    private func processFetchedRecords(_ records: [CKRecord]) async throws {
        try await CoreDataManager.shared.processFetchedCloudKitRecords(records)
    }
    
    private func uploadLocalChanges() async throws {
        let localItems = try await CoreDataManager.shared.fetchLocalItemsPendingCloudKitSync()
        
        for item in localItems {
            try await save(item)
        }
    }
    
    func processSubscriptionNotification(with userInfo: [AnyHashable : Any]) -> Bool {
        os_log("%{public}@", log: log, type: .debug, #function)

        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            os_log("Not a CKNotification", log: log, type: .error)
            return false
        }

//        guard notification.subscriptionID == privateSubscriptionId else {
//            os_log("Not our subscription ID", log: log, type: .debug)
//            return false
//        }

        os_log("Received remote CloudKit notification for user data", log: log, type: .debug)

//        fetchRemoteChanges()

        return true
    }
    
    private func handleDeletedRecord(_ recordID: CKRecord.ID) async throws {
        // Mark the corresponding CoreData object as removed
        try await CoreDataManager.shared.markAsRemoved(cloudKitRecordID: recordID.recordName)
    }
    
    // Add this method to handle record conflicts
    private func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
        // Use server record as the source of truth for now
        // You might want to implement more sophisticated conflict resolution
        return serverRecord
    }
}
