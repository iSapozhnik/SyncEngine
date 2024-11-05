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
    
    var errorDescription: String? {
        switch self {
        case .itemNotValid: return "Clipboard item does not have ID"
        }
    }
}

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
    
    func save(_ clipboardItem: ClipboardItem) async throws {
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
    
    private func createClipboardItemRecord(from item: ClipboardItem) throws -> CKRecord {
        guard let itemID = item.id else {
            throw CloudKitError.itemNotValid
        }
        
        let recordID = item.cloudKitRecordID.map { CKRecord.ID(recordName: $0) } 
            ?? CKRecord.ID(recordName: itemID)
        let record = CKRecord(recordType: "ClipboardItem", recordID: recordID)
        
        record["id"] = item.id
        record["timestamp"] = item.timestamp
        record["modificationDate"] = item.modificationDate
        record["isRemoved"] = item.isRemoved
        
        return record
    }
    
    private func createContentRecord(from content: ClipboardItemContent) throws -> CKRecord {
        guard let contentID = content.id else {
            throw CloudKitError.itemNotValid
        }
        
        let recordID = content.cloudKitRecordID.map { CKRecord.ID(recordName: $0) }
            ?? CKRecord.ID(recordName: contentID)
        let record = CKRecord(recordType: "ClipboardItemContent", recordID: recordID)
        
        record["id"] = content.id
        record["clipboardItemId"] = content.clipboardItemId
        record["timestamp"] = content.timestamp
        record["modificationDate"] = content.modificationDate
        record["isRemoved"] = content.isRemoved
        record["typeIdentifier"] = content.typeIdentifier
        
        // Handle large data using CKAsset if needed
        if let data = content.data {
            if data.count > 1_000_000 {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try data.write(to: tempURL)
                let asset = CKAsset(fileURL: tempURL)
                record["data"] = asset
            } else {
                record["data"] = data
            }
        }
        
        return record
    }
    
    private func fetchContentRecords(for item: ClipboardItem) async throws -> [CKRecord] {
        guard let context = item.managedObjectContext else {
            throw CloudKitError.itemNotValid
        }
        
        let fetchRequest: NSFetchRequest<ClipboardItemContent> = ClipboardItemContent.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "clipboardItemId == %@", item.id ?? "")
        
        let contents = try context.fetch(fetchRequest)
        return try contents.map { try createContentRecord(from: $0) }
    }
    
    private func updateLocalRecords(clipboardItem: ClipboardItem, 
                                  itemRecord: CKRecord, 
                                  contentRecords: [CKRecord]) async throws {
        guard let context = clipboardItem.managedObjectContext else { return }
        
        try await context.perform {
            // Update main item
            clipboardItem.cloudKitRecordID = itemRecord.recordID.recordName
            
            // Update content items
            let fetchRequest: NSFetchRequest<ClipboardItemContent> = ClipboardItemContent.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "clipboardItemId == %@", clipboardItem.id ?? "")
            let contents = try context.fetch(fetchRequest)
            
            for record in contentRecords {
                if let content = contents.first(where: { $0.id == record["id"] as? String }) {
                    content.cloudKitRecordID = record.recordID.recordName
                }
            }
            
            try context.save()
        }
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
        let zoneID = CKRecordZone.default().zoneID
        
        let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
        
        var records: [CKRecord] = []
        for change in changes.modificationResultsByID.values {
            if let record = try? change.get().record {
                records.append(record)
            }
        }
        
        return (changes.changeToken, records)
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
}
