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

class CloudKitSyncEngine {
    static let shared = CloudKitSyncEngine()
    
    private let container: CKContainer
    private let database: CKDatabase
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CloudKitSyncEngine", category: "CloudKit")
    
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
        container = CKContainer.default()
        database = container.privateCloudDatabase
    }
    
    func requestPermission() async throws -> Bool {
        try await container.accountStatus() == .available
    }
    
    func uploadItem(_ item: ClipboardItem) async throws {
        let record = try createRecord(from: item)
        let savedRecord = try await database.save(record)
        try await updateLocalItem(item, with: savedRecord)
    }
    
    func performSync() async throws {
        try await fetchCloudChanges()
        try await uploadLocalChanges()
    }
    
    func deleteItem(_ item: ClipboardItem) async throws {
        guard let recordID = item.cloudKitRecordID.map({ CKRecord.ID(recordName: $0) }) else { return }
        try await database.deleteRecord(withID: recordID)
    }
    
    // MARK: - Private
    
    private func createRecord(from item: ClipboardItem) throws -> CKRecord {
            let recordID = item.cloudKitRecordID.map { CKRecord.ID(recordName: $0) } ?? CKRecord.ID(recordName: item.id)
            let record = CKRecord(recordType: "ClipboardItem", recordID: recordID)
            
            record["id"] = item.id
            record["timestamp"] = item.timestamp
            record["typeIdentifiers"] = item.typeIdentifiers
            
            // Handle large data by splitting into chunks
            for (type, data) in item.data {
                if data.count > 1_000_000 {
                    let asset = CKAsset(data: data)
                    record["\(type)_asset"] = asset
                } else {
                    record[type] = data
                }
            }
            
            return record
        }
    
    private func fetchCloudChanges() async throws {
        var changesToken = syncToken
        
        repeat {
            let (changeToken, records) = try await fetchNextBatch(since: changesToken)
            try await processFetchedRecords(records)
            changesToken = changeToken
        } while changesToken != nil
        
        syncToken = changesToken
    }
    
    private func fetchNextBatch(since token: CKServerChangeToken?) async throws -> (CKServerChangeToken?, [CKRecord]) {
         let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
         configuration.previousServerChangeToken = token
         
         let changes = try await database.recordZoneChanges(inZoneWith: CKRecordZone.default().zoneID, configurationBlock: { _ in configuration })
         return (changes.changeToken, changes.modificationResultsByID.compactMap { $0.value.try?.recordID })
     }
    
    private func processFetchedRecords(_ records: [CKRecord]) async throws {
         let context = CoreDataManager.shared.newBackgroundContext()
         
         try await context.perform {
             for record in records {
                 if let item = try self.findOrCreateItem(for: record, in: context) {
                     try self.update(item, with: record)
                 }
             }
             try context.save()
         }
     }
    
    private func findOrCreateItem(for record: CKRecord, in context: NSManagedObjectContext) throws -> ClipboardItem? {
        let fetchRequest: NSFetchRequest<ClipboardItem> = ClipboardItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@ OR cloudKitRecordID == %@",
                                           record.recordID.recordName, record.recordID.recordName)
        
        let existingItem = try context.fetch(fetchRequest).first
        return existingItem ?? ClipboardItem(context: context)
    }
    
    private func update(_ item: ClipboardItem, with record: CKRecord) throws {
        item.id = record["id"] as? String ?? record.recordID.recordName
        item.timestamp = record["timestamp"] as? Date ?? Date()
        item.typeIdentifiers = record["typeIdentifiers"] as? [String] ?? []
        item.cloudKitRecordID = record.recordID.recordName
        item.modificationDate = record.modificationDate ?? Date()
        
        // Reconstruct data dictionary
        var data: [String: Data] = [:]
        for typeIdentifier in item.typeIdentifiers {
            if let asset = record["\(typeIdentifier)_asset"] as? CKAsset,
               let fileURL = asset.fileURL,
               let assetData = try? Data(contentsOf: fileURL) {
                data[typeIdentifier] = assetData
            } else if let recordData = record[typeIdentifier] as? Data {
                data[typeIdentifier] = recordData
            }
        }
        item.data = data
    }
    
    private func uploadLocalChanges() async throws {
        let context = CoreDataManager.shared.newBackgroundContext()
        let fetchRequest: NSFetchRequest<ClipboardItem> = ClipboardItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "cloudKitRecordID == NULL")
        
        let localItems = try await context.perform {
            try context.fetch(fetchRequest)
        }
        
        for item in localItems {
            try await uploadItem(item)
        }
    }
}
