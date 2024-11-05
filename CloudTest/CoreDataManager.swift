//
//  CoreDataManager.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 05.11.24.
//

import Foundation
import CoreData
import os.log
import AppKit
import CloudKit

class CoreDataManager {
    
    private let container: NSPersistentContainer
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoreDataManager", category: "CoreData")

    static let shared = CoreDataManager()
    
    init() {
        container = NSPersistentContainer(name: "CloudTest")
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("Failed to retrieve persistent store description")
        }
        // Enable history tracking for sync
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        container.loadPersistentStores { [weak self] description, error in
            if let error = error {
                self?.logger.error("Core Data failed to load: \(error.localizedDescription)")
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
            
            self?.container.viewContext.automaticallyMergesChangesFromParent = true
            self?.container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            
            self?.container.viewContext.shouldDeleteInaccessibleFaults = true
            self?.container.viewContext.name = "viewContext"
            
            // Start sync
            self?.container.viewContext.perform {
                self?.setupSync()
            }
        }
        
        // Observe changes from other processes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeRemoteChange),
            name: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator
        )
        
        // Observe CloudKit account changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudKitAccountChanged),
            name: .CKAccountChanged,
            object: nil
        )
    }
    
    func saveClipboardContent() async throws {
        guard NSPasteboard.general.pasteboardItems?.isEmpty != true else {
            throw ClipboardError.invalidPasteboardContent
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    guard let pasteboardItems = NSPasteboard.general.pasteboardItems else {
                        continuation.resume(throwing: ClipboardError.invalidPasteboardContent)
                        return
                    }
                    
                    // Create a task group to handle CloudKit saves
                    let taskGroup = Task {
                        for pasteboard in pasteboardItems {
                            guard let identifier = ClipboardIdentifier.generateUniqueIdentifier(pasteboard) else {
                                continue
                            }
                            
                            // Create new clipboard item
                            let clipboardItem = ClipboardItem(context: context)
                            clipboardItem.id = identifier
                            clipboardItem.timestamp = Date()
                            clipboardItem.modificationDate = Date()
                            clipboardItem.isRemoved = false
                            
                            // Store data for each type as separate ClipboardItemContent
                            for type in pasteboard.types {
                                if let data = pasteboard.data(forType: type) {
                                    let content = ClipboardItemContent(context: context)
                                    content.clipboardItemId = identifier
                                    content.id = UUID().uuidString
                                    content.typeIdentifier = type.rawValue
                                    content.data = data
                                    content.timestamp = Date()
                                    content.modificationDate = Date()
                                    content.isRemoved = false
                                }
                            }
                            
                            // Save to CloudKit
                            do {
                                try await CloudKitSyncEngine.shared.save(clipboardItem)
                                self.logger.info("Saved clipboard item to CloudKit: \(identifier)")
                            } catch {
                                self.logger.error("Failed to save to CloudKit: \(error.localizedDescription)")
                            }
                        }
                    }
                    
                    // Save to Core Data
                    try context.save()
                    
                    continuation.resume()
                    
                } catch {
                    self.logger.error("Failed to save clipboard item: \(error.localizedDescription)")
                    continuation.resume(throwing: ClipboardError.saveFailed(error))
                }
            }
        }
    }
    
    func restoreClipboardContent(_ identifier: String) async throws {
        /*
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    // Fetch ClipboardItemContent entries for the given identifier
                    let fetchRequest: NSFetchRequest<ClipboardItemContent> = ClipboardItemContent.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "clipboardItemId == %@ AND isRemoved == NO", identifier)
                    
                    let contents = try context.fetch(fetchRequest)
                    guard !contents.isEmpty else {
                        throw ClipboardError.itemNotFound
                    }
                    
                    DispatchQueue.main.async {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        
                        for content in contents {
                            guard let typeIdentifier = content.typeIdentifier,
                                  let data = content.data else { continue }
                            
                            let type = NSPasteboard.PasteboardType(rawValue: typeIdentifier)
                            pasteboard.setData(data, forType: type)
                        }
                        continuation.resume()
                    }
                    
                } catch {
                    continuation.resume(throwing: ClipboardError.fetchFailed(error))
                }
            }
        }
         */
    }
    
    func deleteItem(_ identifier: String) async throws {
        /*
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    // Delete associated ClipboardItemContent entries
                    let contentFetchRequest: NSFetchRequest<ClipboardItemContent> = ClipboardItemContent.fetchRequest()
                    contentFetchRequest.predicate = NSPredicate(format: "clipboardItemId == %@", identifier)
                    let contents = try context.fetch(contentFetchRequest)
                    
                    for content in contents {
                        context.delete(content)
                    }
                    
                    // Delete the ClipboardItem
                    let itemFetchRequest: NSFetchRequest<ClipboardItem> = ClipboardItem.fetchRequest()
                    itemFetchRequest.predicate = NSPredicate(format: "id == %@", identifier)
                    
                    if let item = try context.fetch(itemFetchRequest).first {
                        context.delete(item)
                    }
                    
                    try context.save()
                    self.logger.info("Deleted clipboard item and contents with ID: \(identifier)")
                    
                    continuation.resume()
                } catch {
                    self.logger.error("Failed to delete item: \(error.localizedDescription)")
                    continuation.resume(throwing: ClipboardError.saveFailed(error))
                }
            }
        }
         */
    }
    
    func performMaintenance() async throws {
        /*
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
                    
                    // Delete old ClipboardItemContent entries
                    let contentFetchRequest: NSFetchRequest<NSFetchRequestResult> = ClipboardItemContent.fetchRequest()
                    contentFetchRequest.predicate = NSPredicate(format: "timestamp < %@", thirtyDaysAgo as NSDate)
                    
                    let contentBatchDelete = NSBatchDeleteRequest(fetchRequest: contentFetchRequest)
                    contentBatchDelete.resultType = .resultTypeObjectIDs
                    
                    let contentResult = try context.execute(contentBatchDelete) as? NSBatchDeleteResult
                    let contentObjectIDArray = contentResult?.result as? [NSManagedObjectID] ?? []
                    
                    // Delete old ClipboardItem entries
                    let itemFetchRequest: NSFetchRequest<NSFetchRequestResult> = ClipboardItem.fetchRequest()
                    itemFetchRequest.predicate = NSPredicate(format: "timestamp < %@", thirtyDaysAgo as NSDate)
                    
                    let itemBatchDelete = NSBatchDeleteRequest(fetchRequest: itemFetchRequest)
                    itemBatchDelete.resultType = .resultTypeObjectIDs
                    
                    let itemResult = try context.execute(itemBatchDelete) as? NSBatchDeleteResult
                    let itemObjectIDArray = itemResult?.result as? [NSManagedObjectID] ?? []
                    
                    // Sync changes with view context
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: [NSDeletedObjectsKey: contentObjectIDArray + itemObjectIDArray],
                        into: [self.container.viewContext]
                    )
                    
                    self.logger.info("Maintenance completed: deleted \(itemObjectIDArray.count) items and \(contentObjectIDArray.count) content entries")
                    continuation.resume()
                } catch {
                    self.logger.error("Maintenance failed: \(error.localizedDescription)")
                    continuation.resume(throwing: ClipboardError.saveFailed(error))
                }
            }
        }
         */
    }
    
    private func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.shouldDeleteInaccessibleFaults = true
        return context
    }
    
    private func setupSync() {
//        container.cloudKitContainer.accountStatus { [weak self] status, error in
//            if status == .available {
//                self?.initiateSync()
//            } else if let error = error {
//                self?.logger.error("CloudKit account error: \(error.localizedDescription)")
//            }
//        }
    }
    
    @objc private func storeRemoteChange(_ notification: Notification) {
        logger.info("Received remote change notification")
        container.viewContext.perform {
            self.container.viewContext.refreshAllObjects()
        }
    }
    
    private func initiateSync() {
//        Task {
//            do {
//                try await container.sync()
//                logger.info("CloudKit sync completed successfully")
//            } catch {
//                logger.error("CloudKit sync failed: \(error.localizedDescription)")
//            }
//        }
    }
    
    @objc private func cloudKitAccountChanged(_ notification: Notification) {
        container.viewContext.perform { [weak self] in
            self?.setupSync()
        }
    }
    
    func fetchLocalItemsPendingCloudKitSync() async throws -> [ClipboardItem] {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    let fetchRequest: NSFetchRequest<ClipboardItem> = ClipboardItem.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "cloudKitRecordID == NULL")
                    
                    let items = try context.fetch(fetchRequest)
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func processFetchedCloudKitRecords(_ records: [CKRecord]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    for record in records {
                        switch record.recordType {
                        case "ClipboardItem":
                            let fetchRequest: NSFetchRequest<ClipboardItem> = ClipboardItem.fetchRequest()
                            fetchRequest.predicate = NSPredicate(format: "id == %@ OR cloudKitRecordID == %@",
                                                             record.recordID.recordName, record.recordID.recordName)
                            
                            let item = try context.fetch(fetchRequest).first ?? ClipboardItem(context: context)
                            item.id = record["id"] as? String ?? record.recordID.recordName
                            item.timestamp = record["timestamp"] as? Date ?? Date()
                            item.modificationDate = record.modificationDate ?? Date()
                            item.isRemoved = record["isRemoved"] as? Bool ?? false
                            item.cloudKitRecordID = record.recordID.recordName
                            
                        case "ClipboardItemContent":
                            let fetchRequest: NSFetchRequest<ClipboardItemContent> = ClipboardItemContent.fetchRequest()
                            fetchRequest.predicate = NSPredicate(format: "id == %@ OR cloudKitRecordID == %@",
                                                               record["id"] as? String ?? "", 
                                                               record.recordID.recordName)
                            
                            let content = try context.fetch(fetchRequest).first ?? ClipboardItemContent(context: context)
                            content.id = record["id"] as? String
                            content.clipboardItemId = record["clipboardItemId"] as? String
                            content.timestamp = record["timestamp"] as? Date
                            content.modificationDate = record.modificationDate
                            content.isRemoved = record["isRemoved"] as? Bool ?? false
                            content.typeIdentifier = record["typeIdentifier"] as? String
                            content.cloudKitRecordID = record.recordID.recordName
                            
                            if let asset = record["data"] as? CKAsset, let fileURL = asset.fileURL {
                                content.data = try Data(contentsOf: fileURL)
                            } else if let data = record["data"] as? Data {
                                content.data = data
                            }
                            
                        default:
                            break
                        }
                    }
                    
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

