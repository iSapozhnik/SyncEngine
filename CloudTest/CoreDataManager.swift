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
                NSPasteboard.general.pasteboardItems?.forEach { pasteboard in
                    guard let identifier = ClipboardIdentifier.generateUniqueIdentifier(pasteboard) else {
                        throw ClipboardError.invalidPasteboardContent
                    }
                    
                    do {
                        // Create new clipboard item
                        let clipboardItem = ClipboardItem(context: context)
                        clipboardItem.id = identifier
                        clipboardItem.timestamp = Date()
                        clipboardItem.typeIdentifiers = Array(pasteboard.types.map { $0.rawValue }).joined(separator: ",")
                        clipboardItem.modificationDate = Date()
                        clipboardItem.isRemoved = false
                        
                        // Store data
                        var storedData: [String: Data] = [:]
                        for type in pasteboard.types {
                            if let data = pasteboard.data(forType: type) {
                                storedData[type.rawValue] = data
                            }
                        }
    //                        clipboardItem.data = storedData
                        
                        // Save to Core Data
                        try context.save()
                        
                        // Save to CloudKit
                        Task {
                            do {
                                try await CloudKitSyncEngine.shared.save(clipboardItem)
                                self.logger.info("Saved clipboard item to CloudKit: \(identifier)")
                            } catch {
                                self.logger.error("Failed to save to CloudKit: \(error.localizedDescription)")
                            }
                        }
                        
                        continuation.resume()
                    } catch {
                        self.logger.error("Failed to save clipboard item: \(error.localizedDescription)")
                        continuation.resume(throwing: ClipboardError.saveFailed(error))
                    }
                }
            }
        }
        
    }
    
    func restoreClipboardContent(_ identifier: String) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    let fetchRequest: NSFetchRequest<ClipboardItem> = ClipboardItem.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", identifier)
                    
                    guard let item = try context.fetch(fetchRequest).first else {
                        throw ClipboardError.itemNotFound
                    }
                    DispatchQueue.main.async {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        let typeIdentifiers = (item.typeIdentifiers ?? "").split(separator: ",").map { String($0) }
                        for typeString in typeIdentifiers {
                            //                                guard
                            //                                    let type = NSPasteboard.PasteboardType(rawValue: typeString),
                            //                                    let data = item.data[typeString] else { continue }
                            let type = NSPasteboard.PasteboardType(rawValue: typeString)
                            
                            pasteboard.setData("data".data(using: .utf8), forType: type)
                        }
                        continuation.resume()
                    }
                    
                } catch {
                    continuation.resume(throwing: ClipboardError.fetchFailed(error))
                }
            }
        }
    }
    
    func deleteItem(_ identifier: String) async throws {
            return try await withCheckedThrowingContinuation { continuation in
                let context = newBackgroundContext()
                
                context.performAndWait {
                    do {
                        let fetchRequest: NSFetchRequest<ClipboardItem> = ClipboardItem.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "id == %@", identifier)
                        
                        if let item = try context.fetch(fetchRequest).first {
                            context.delete(item)
                            try context.save()
                            self.logger.info("Deleted clipboard item with ID: \(identifier)")
                        }
                        
                        continuation.resume()
                    } catch {
                        self.logger.error("Failed to delete item: \(error.localizedDescription)")
                        continuation.resume(throwing: ClipboardError.saveFailed(error))
                    }
                }
            }
        }
    
    func performMaintenance() async throws {
            return try await withCheckedThrowingContinuation { continuation in
                let context = newBackgroundContext()
                
                context.performAndWait {
                    do {
                        // Delete items older than 30 days
                        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
                        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = ClipboardItem.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "timestamp < %@", thirtyDaysAgo as NSDate)
                        
                        // Use batch delete for better performance
                        let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                        batchDelete.resultType = .resultTypeObjectIDs
                        
                        let result = try context.execute(batchDelete) as? NSBatchDeleteResult
                        let objectIDArray = result?.result as? [NSManagedObjectID] ?? []
                        
                        // Sync changes with view context
                        NSManagedObjectContext.mergeChanges(
                            fromRemoteContextSave: [NSDeletedObjectsKey: objectIDArray],
                            into: [self.container.viewContext]
                        )
                        
                        self.logger.info("Maintenance completed: deleted \(objectIDArray.count) old items")
                        continuation.resume()
                    } catch {
                        self.logger.error("Maintenance failed: \(error.localizedDescription)")
                        continuation.resume(throwing: ClipboardError.saveFailed(error))
                    }
                }
            }
        }
    
    private func newBackgroundContext() -> NSManagedObjectContext {
            let context = container.newBackgroundContext()
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            context.shouldDeleteInaccessibleFaults = true
            return context
        }
    
    private func setupSync() {
        container.cloudKitContainer.accountStatus { [weak self] status, error in
            if status == .available {
                self?.initiateSync()
            } else if let error = error {
                self?.logger.error("CloudKit account error: \(error.localizedDescription)")
            }
        }
    }
    
    @objc private func storeRemoteChange(_ notification: Notification) {
            logger.info("Received remote change notification")
            container.viewContext.perform {
                self.container.viewContext.refreshAllObjects()
            }
        }
    
    private func initiateSync() {
        Task {
            do {
                try await container.sync()
                logger.info("CloudKit sync completed successfully")
            } catch {
                logger.error("CloudKit sync failed: \(error.localizedDescription)")
            }
        }
    }
    
    @objc private func cloudKitAccountChanged(_ notification: Notification) {
        container.viewContext.perform { [weak self] in
            self?.setupSync()
        }
    }
}

