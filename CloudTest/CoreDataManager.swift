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

@MainActor
final class CoreDataManager {
    
    private let container: NSPersistentContainer
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoreDataManager", category: "CoreData")

    static let shared = CoreDataManager()
    private var syncEngine: SyncEngine?
    
    var progressHandler: ((Double) -> Void)? = nil
    var stateStream: AsyncStream<SyncState>?
    
    var updateUI: () -> Void = {}

    private init() {
        container = NSPersistentContainer(name: "CloudTest")
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("Failed to retrieve persistent store description")
        }
        
        // Enable history tracking for sync
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        // Load stores synchronously since this is a private initializer
        container.loadPersistentStores { [weak self] description, error in
            if let error = error {
                self?.logger.error("Core Data failed to load: \(error.localizedDescription)")
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
            
            self?.setupViewContext()
        }
        
        setupNotificationObservers()
    }

    private func setupViewContext() {
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.shouldDeleteInaccessibleFaults = true
        container.viewContext.name = "viewContext"
        
        // Start sync
        Task { @MainActor in
            await setupSync()
        }
    }
    
    private func setupNotificationObservers() {
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
    
    private func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    // MARK: - Sync Setup
    
    private func setupSync() async {
        do {
            let storedItems = try await fetchClipboardItems()
            let syncEngine = SyncEngine(
                syncConfig: SyncConfig.default,
                defaults: UserDefaults.standard,
                initialModels: storedItems
            )
            stateStream = syncEngine.syncState
            syncEngine.register(ClipboardItem.self)
            syncEngine.register(ClipboardItemContent.self)
            
            if try await syncEngine.requestPermission() {
                syncEngine.progressHandler = { [weak self] progress in
                    guard let self else { return }
                    Task { @MainActor in
                        self.progressHandler?(progress)
                        self.logger.debug("progress: \(progress)%")
                    }
                }
                
                let typeMapping: [String: Any.Type] = [
                    "ClipboardItem": ClipboardItem.self,
                    "ClipboardItemContent": ClipboardItemContent.self
                ]
                syncEngine.didUpdateModels = { [weak self] models in
                    guard let self else { return }
                    
                    var clipboardItems: [ClipboardItem] = []
                    var clipboardItemContents: [ClipboardItemContent] = []
                    
                    for (key, models) in models {
                        guard let type = typeMapping[key] else { continue }
                        switch type {
                        case is ClipboardItem.Type:
                            clipboardItems = models.compactMap { $0 as? ClipboardItem }
                        case is ClipboardItemContent.Type:
                            clipboardItemContents = models.compactMap { $0 as? ClipboardItemContent }
                        default: break
                        }
                    }
                    
                    Task {
                        do {
                            try await self.processClipboardItemCloudKitRecords(clipboardItems)
                            try await self.processClipboardItemContentCloudKitRecords(clipboardItemContents)
                            await MainActor.run {
                                self.updateUI()
                            }
                        } catch {
                            self.logger.error("Failed to process sync updates: \(error)")
                        }
                    }
                }
                
                syncEngine.didDeleteModels = { [weak self] identifiers in
                    guard let self else { return }
                    Task {
                        do {
                            try await self.deleteItem(identifiers)
                            await MainActor.run {
                                self.updateUI()
                            }
                        } catch {
                            self.logger.error("Failed to process deletions: \(error)")
                        }
                    }
                }
                
                try await syncEngine.start()
                self.syncEngine = syncEngine
            }
        } catch {
            logger.error("CloudKit setup failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Core Data Operations
    
    func saveClipboardData(_ clipboardData: ClipboardData) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    let fetchRequest: NSFetchRequest<ClipboardItemMO> = ClipboardItemMO.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id == %@", clipboardData.identifier)

                    let existingItemsCount = try context.count(for: fetchRequest)
                    if existingItemsCount > 0 {
                        // Item already exists, skip saving
                        continuation.resume(returning: false)
                        return
                    }
                    
                    // Create new clipboard item
                    let date = Date()
                    let clipboardItem = ClipboardItemMO(context: context)
                    clipboardItem.id = clipboardData.identifier
                    clipboardItem.timestamp = clipboardData.timestamp
                    clipboardItem.updatedDate = date
                    clipboardItem.isRemoved = false
                    
                    var contentItems: [ClipboardItemContent] = []
                    
                    // Store data for each type
                    for type in clipboardData.types {
                        if let data = clipboardData.contents[type] {
                            let content = ClipboardItemContentMO(context: context)
                            content.clipboardItemId = clipboardData.identifier
                            content.id = UUID().uuidString
                            content.typeIdentifier = type.rawValue
                            content.data = data
                            content.timestamp = clipboardData.timestamp
                            content.updatedDate = date
                            content.isRemoved = false
                            
                            // Create ClipboardItemContent for sync
                            let contentItem = ClipboardItemContent(
                                id: content.id ?? "",
                                clipboardItemId: clipboardData.identifier,
                                typeIdentifier: type.rawValue,
                                data: content.data ?? Data(),
                                timestamp: date,
                                updatedDate: date,
//                                isRemoved: content.isRemoved,
                                cloudKitRecordID: content.cloudKitRecordID
                            )
                            contentItems.append(contentItem)
                        }
                    }
                    
                    try context.save()
                    continuation.resume(returning: true)

                    // Create ClipboardItem for sync
                    let item = ClipboardItem(
                        id: clipboardData.identifier,
                        timestamp: date,
                        updatedDate: date,
                        cloudKitRecordID: clipboardItem.cloudKitRecordID,
                        contents: contentItems
                    )
                    
                    // Upload to CloudKit
                    let uploads = ([item as any Syncable] + contentItems as [any Syncable])
                    
                    Task {
                        try await syncEngine?.uploadAnys(contentItems)
                        // Then upload the main item with references to contents
                        try await syncEngine?.upload(item)
                    }
                    
                    
                } catch {
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
    
    func deleteItem(_ identifiers: [String]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                
                do {
                    for identifier in identifiers {
                        // Delete associated ClipboardItemContent entries
                        let contentFetchRequest: NSFetchRequest<ClipboardItemContentMO> = ClipboardItemContentMO.fetchRequest()
                        contentFetchRequest.predicate = NSPredicate(format: "clipboardItemId == %@", identifier)
                        contentFetchRequest.includesPropertyValues = false
                        let contents = try context.fetch(contentFetchRequest)
                        
                        for content in contents {
                            context.delete(content)
                        }
                        
                        // Delete the ClipboardItem
                        let itemFetchRequest: NSFetchRequest<ClipboardItemMO> = ClipboardItemMO.fetchRequest()
                        itemFetchRequest.predicate = NSPredicate(format: "id == %@", identifier)
                        itemFetchRequest.includesPropertyValues = false
                        
                        if let item = try context.fetch(itemFetchRequest).first {
                            context.delete(item)
                            self.logger.info("Deleted clipboard item and contents with ID: \(identifier)")
                        }
                    }
                    
                    try context.save()

                    continuation.resume()
                } catch {
                    self.logger.error("Failed to delete item: \(error.localizedDescription)")
                    continuation.resume(throwing: ClipboardError.saveFailed(error))
                }

            }
        }
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
    
    func fetchLocalItemsPendingCloudKitSync() async throws -> [ClipboardItem] {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    let fetchRequest: NSFetchRequest<ClipboardItemMO> = ClipboardItemMO.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "cloudKitRecordID == NULL")
                    
                    let managedObjects = try context.fetch(fetchRequest)
                    let items = try managedObjects.map { managedObject -> ClipboardItem in
                        let contentsFetchRequest: NSFetchRequest<ClipboardItemContentMO> = ClipboardItemContentMO.fetchRequest()
                        contentsFetchRequest.predicate = NSPredicate(format: "clipboardItemId == %@", managedObject.id ?? "")
                        
                        let contentManagedObjects = try context.fetch(contentsFetchRequest)
                        let contents = contentManagedObjects.map { ClipboardItemContent(managedObject: $0) }
                        
                        return ClipboardItem(
                            id: managedObject.id ?? "",
                            timestamp: managedObject.timestamp ?? Date(),
                            updatedDate: managedObject.updatedDate ?? Date(),
                            cloudKitRecordID: managedObject.cloudKitRecordID,
                            contents: contents
                        )
                    }
                    
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func processClipboardItemCloudKitRecords(_ clipboatdItems: [ClipboardItem]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    let clipboardItemIds = clipboatdItems.map(\.id)
                    let fetchRequest: NSFetchRequest<ClipboardItemMO> = ClipboardItemMO.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id IN %@", clipboardItemIds)
                    
                    let existingItems = try context.fetch(fetchRequest)
                    let existingItemsDict = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id!, $0) })
                    
                    for clipboardItem in clipboatdItems {
                        if let existingItem = existingItemsDict[clipboardItem.id] {
                            existingItem.ckData = clipboardItem.ckData
                            logger.debug("Did update ckData for item id: \(clipboardItem.id)")
                        } else {
                            let newClipboardItem = ClipboardItemMO(context: context)
                            newClipboardItem.id = clipboardItem.id
                            newClipboardItem.timestamp = clipboardItem.timestamp
                            newClipboardItem.updatedDate = clipboardItem.updatedDate
                            newClipboardItem.ckData = clipboardItem.ckData
                            newClipboardItem.cloudKitRecordID = clipboardItem.cloudKitRecordID
                            
                            for clipboardItemContent in clipboardItem.contents {
                                let content = ClipboardItemContentMO(context: context)
                                content.clipboardItemId = clipboardItemContent.clipboardItemId
                                content.id = clipboardItemContent.id
                                content.typeIdentifier = clipboardItemContent.typeIdentifier
                                content.data = clipboardItemContent.data
                                content.updatedDate = clipboardItemContent.updatedDate
                                content.timestamp = clipboardItemContent.timestamp
                                content.clipboardItemId = clipboardItemContent.clipboardItemId
                                content.ckData = clipboardItemContent.ckData
                                content.cloudKitRecordID = clipboardItemContent.cloudKitRecordID
                            }
                            logger.debug("Did create new item from CKRecord")
                        }
                    }
                        
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                    context.rollback()
                }
            }
        }
    }
    
    func processClipboardItemContentCloudKitRecords(_ clipboardItemContents: [ClipboardItemContent]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    // Fetch all existing items at once
                    let contentIds = clipboardItemContents.map { $0.id }
                    let fetchRequest: NSFetchRequest<ClipboardItemContentMO> = ClipboardItemContentMO.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "id IN %@", contentIds)
                    
                    let existingContents = try context.fetch(fetchRequest)
                    let existingContentsDict = Dictionary(uniqueKeysWithValues: existingContents.map { ($0.id!, $0) })
                    
                    for clipboardItemContent in clipboardItemContents {
                        if let existingContent = existingContentsDict[clipboardItemContent.id] {
                            // Update existing content
                            existingContent.ckData = clipboardItemContent.ckData
                            existingContent.cloudKitRecordID = clipboardItemContent.cloudKitRecordID
                            logger.debug("Did update ckData for itemContent id: \(clipboardItemContent.id)")
                        } else {
                            // Create new content
                            let newContent = ClipboardItemContentMO(context: context)
                            newContent.clipboardItemId = clipboardItemContent.clipboardItemId
                            newContent.id = clipboardItemContent.id
                            newContent.typeIdentifier = clipboardItemContent.typeIdentifier
                            newContent.data = clipboardItemContent.data
                            newContent.updatedDate = clipboardItemContent.updatedDate
                            newContent.timestamp = clipboardItemContent.timestamp
                            newContent.ckData = clipboardItemContent.ckData
                            newContent.cloudKitRecordID = clipboardItemContent.cloudKitRecordID
                            logger.debug("Did create new content from CKRecord")
                        }
                    }
                    
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                    context.rollback()
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
                            let fetchRequest: NSFetchRequest<ClipboardItemMO> = ClipboardItemMO.fetchRequest()
                            fetchRequest.predicate = NSPredicate(format: "id == %@ OR cloudKitRecordID == %@",
                                                             record.recordID.recordName, record.recordID.recordName)
                            
                            let item = try context.fetch(fetchRequest).first ?? ClipboardItemMO(context: context)
                            item.id = record["id"] as? String ?? record.recordID.recordName
                            item.timestamp = record["timestamp"] as? Date ?? Date()
                            item.updatedDate = record.modificationDate ?? Date()
                            item.isRemoved = record["isRemoved"] as? Bool ?? false
                            item.cloudKitRecordID = record.recordID.recordName
                            
                        case "ClipboardItemContent":
                            let fetchRequest: NSFetchRequest<ClipboardItemContentMO> = ClipboardItemContentMO.fetchRequest()
                            fetchRequest.predicate = NSPredicate(format: "id == %@ OR cloudKitRecordID == %@",
                                                               record["id"] as? String ?? "", 
                                                               record.recordID.recordName)
                            
                            let content = try context.fetch(fetchRequest).first ?? ClipboardItemContentMO(context: context)
                            content.id = record["id"] as? String
                            content.clipboardItemId = record["clipboardItemId"] as? String
                            content.timestamp = record["timestamp"] as? Date
                            content.updatedDate = record.modificationDate
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
    
    func fetchClipboardItems() async throws -> [ClipboardItem] {
        try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    let fetchRequest: NSFetchRequest<ClipboardItemMO> = ClipboardItemMO.fetchRequest()
                    fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ClipboardItemMO.timestamp, ascending: false)]
                    let managedObjects = try context.fetch(fetchRequest)
                    var items: [ClipboardItem] = []
                    
                    for managedObject in managedObjects {
                        let contentsFetchRequest: NSFetchRequest<ClipboardItemContentMO> = ClipboardItemContentMO.fetchRequest()
                        contentsFetchRequest.predicate = NSPredicate(format: "clipboardItemId == %@", managedObject.id ?? "")
                        
                        let contentMOs = try context.fetch(contentsFetchRequest)
                        let item = ClipboardItem(managedObject: managedObject, contents: contentMOs)
                        items.append(item)
                    }
                    
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func updateCloudKitRecords(for clipboardItem: ClipboardItem,
                              itemRecord: CKRecord,
                              contentRecords: [CKRecord]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    // Fetch and update main item
                    let itemFetchRequest: NSFetchRequest<ClipboardItemMO> = ClipboardItemMO.fetchRequest()
                    itemFetchRequest.predicate = NSPredicate(format: "id == %@", clipboardItem.id)
                    
                    if let managedItem = try context.fetch(itemFetchRequest).first {
                        managedItem.cloudKitRecordID = itemRecord.recordID.recordName
                        
                        // Update content items
                        let contentFetchRequest: NSFetchRequest<ClipboardItemContentMO> = ClipboardItemContentMO.fetchRequest()
                        contentFetchRequest.predicate = NSPredicate(format: "clipboardItemId == %@", clipboardItem.id)
                        let contents = try context.fetch(contentFetchRequest)
                        
                        for record in contentRecords {
                            if let content = contents.first(where: { $0.id == record["id"] as? String }) {
                                content.cloudKitRecordID = record.recordID.recordName
                            }
                        }
                        
                        try context.save()
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CloudKitError.itemNotFound)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func markAsRemoved(cloudKitRecordID: String) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    // Check both ClipboardItem and ClipboardItemContent
                    let itemFetchRequest: NSFetchRequest<ClipboardItemMO> = ClipboardItemMO.fetchRequest()
                    itemFetchRequest.predicate = NSPredicate(format: "cloudKitRecordID == %@", cloudKitRecordID)
                    
                    let contentFetchRequest: NSFetchRequest<ClipboardItemContentMO> = ClipboardItemContentMO.fetchRequest()
                    contentFetchRequest.predicate = NSPredicate(format: "cloudKitRecordID == %@", cloudKitRecordID)
                    
                    if let item = try context.fetch(itemFetchRequest).first {
                        item.isRemoved = true
                    }
                    
                    if let content = try context.fetch(contentFetchRequest).first {
                        content.isRemoved = true
                    }
                    
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func eraseLocalStorage() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let context = newBackgroundContext()
            
            context.performAndWait {
                do {
                    // Fetch and delete all ClipboardItemContent objects
                    let contentFetchRequest: NSFetchRequest<NSFetchRequestResult> = ClipboardItemContentMO.fetchRequest()
                    let contentDeleteRequest = NSBatchDeleteRequest(fetchRequest: contentFetchRequest)
                    try context.execute(contentDeleteRequest)
                    
                    // Fetch and delete all ClipboardItem objects
                    let itemFetchRequest: NSFetchRequest<NSFetchRequestResult> = ClipboardItemMO.fetchRequest()
                    let itemDeleteRequest = NSBatchDeleteRequest(fetchRequest: itemFetchRequest)
                    try context.execute(itemDeleteRequest)
                    
                    // Save the context to persist the deletions
                    try context.save()
                    
                    // Reset the view context synchronously
                    self.container.viewContext.performAndWait {
                        self.container.viewContext.reset()
                    }
                    
                    logger.info("Local storage successfully erased")
                    continuation.resume()
                } catch {
                    logger.error("Failed to erase local storage: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func processSubscriptionNotification(with userInfo: [AnyHashable : Any]) {
        Task {
            await syncEngine?.processSubscriptionNotification(with: userInfo)
        }
    }
    
    @objc private func storeRemoteChange(_ notification: Notification) {
        Task { @MainActor in
            container.viewContext.refreshAllObjects()
        }
    }
    
    @objc private func cloudKitAccountChanged(_ notification: Notification) {
        Task { @MainActor in
            await setupSync()
        }
    }
}

// MARK: - Error Types
enum CoreDataError: LocalizedError {
    case saveFailed(Error)
    case fetchFailed(Error)
    case invalidData
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .saveFailed(let error): return "Failed to save: \(error.localizedDescription)"
        case .fetchFailed(let error): return "Failed to fetch: \(error.localizedDescription)"
        case .invalidData: return "Invalid data"
        case .unknown: return "Unknown error"
        }
    }
}

