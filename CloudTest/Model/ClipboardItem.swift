import AppKit
import CloudKit

// MARK: - ClipboardItem
struct ClipboardItem {
    var ckData: Data? = nil
    let id: String
    let timestamp: Date
    let updatedDate: Date
    let isRemoved: Bool
    let cloudKitRecordID: String?
    let contents: [ClipboardItemContent]
}

// MARK: - Record Keys
extension RecordKeys {
    struct ClipboardItem {
        static var id: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "id") }
        static var timestamp: RecordKeyPath<NSDate> { RecordKeyPath(rawValue: "timestamp") }
        static var updatedDate: RecordKeyPath<NSDate> { RecordKeyPath(rawValue: "updatedDate") }
        static var isRemoved: RecordKeyPath<NSNumber> { RecordKeyPath(rawValue: "isRemoved") }
        static var contents: RecordKeyPath<NSArray> { RecordKeyPath(rawValue: "contents") }
    }
    
    struct ClipboardItemContent {
        static var id: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "id") }
        static var clipboardItemId: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "clipboardItemId") }
        static var typeIdentifier: RecordKeyPath<NSString> { RecordKeyPath(rawValue: "typeIdentifier") }
        static var data: RecordKeyPath<NSData> { RecordKeyPath(rawValue: "data") }
        static var timestamp: RecordKeyPath<NSDate> { RecordKeyPath(rawValue: "timestamp") }
        static var updatedDate: RecordKeyPath<NSDate> { RecordKeyPath(rawValue: "updatedDate") }
        static var isRemoved: RecordKeyPath<NSNumber> { RecordKeyPath(rawValue: "isRemoved") }
        static var parent: RecordKeyPath<CKRecord.Reference> { RecordKeyPath(rawValue: "parent") }
    }
}

// MARK: - CloudKitRecord

extension ClipboardItem: CloudKitRecord {
    static var recordType: String { "ClipboardItem" }
    
    var recordKeys: [String: CKRecordValue] {
        var keys: [String: CKRecordValue] = [
            RecordKeys.ClipboardItem.id.rawValue: id as NSString,
            RecordKeys.ClipboardItem.timestamp.rawValue: timestamp as NSDate,
            RecordKeys.ClipboardItem.updatedDate.rawValue: updatedDate as NSDate,
            RecordKeys.ClipboardItem.isRemoved.rawValue: isRemoved as NSNumber
        ]
        
        // Only add contents if there are any
        if !contents.isEmpty {
            let contentReferences = contents.map { content -> CKRecord.Reference in
                let contentRecordID = CKRecord.ID(
                    recordName: content.id,
                    zoneID: SyncConstants.customZoneID
                )
                return CKRecord.Reference(
                    recordID: contentRecordID,
                    action: .deleteSelf
                )
            }
            keys[RecordKeys.ClipboardItem.contents.rawValue] = contentReferences as NSArray
        }
        
        return keys
    }
}

// MARK: - ClipboardItem Extensions
extension ClipboardItem {
    init(
        id: String,
        timestamp: Date,
        updatedDate: Date,
        isRemoved: Bool,
        cloudKitRecordID: String? = nil,
        contents: [ClipboardItemContent]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.updatedDate = updatedDate
        self.isRemoved = isRemoved
        self.cloudKitRecordID = cloudKitRecordID
        self.contents = contents
    }
    
    init(managedObject: ClipboardItemMO) {
        self.id = managedObject.id ?? ""
        self.timestamp = managedObject.timestamp ?? Date()
        self.updatedDate = managedObject.updatedDate ?? Date()
        self.isRemoved = managedObject.isRemoved
        self.cloudKitRecordID = managedObject.cloudKitRecordID
        self.contents = [] // Will be populated separately
    }
    
    init?(from record: CKRecord) {
        guard
            let id = record[RecordKeys.ClipboardItem.id] as? String,
            let timestamp = record[RecordKeys.ClipboardItem.timestamp] as? Date,
            let updatedDate = record[RecordKeys.ClipboardItem.updatedDate] as? Date,
            let isRemoved = record[RecordKeys.ClipboardItem.isRemoved] as? Bool
        else { return nil }
        
        self.id = id
        self.timestamp = timestamp
        self.updatedDate = updatedDate
        self.isRemoved = isRemoved
        self.cloudKitRecordID = record.recordID.recordName
        self.ckData = record.encodedSystemFields
        self.contents = [] // Will be populated separately
    }
}

// MARK: - ClipboardItemContent
struct ClipboardItemContent: CloudKitRecord {
    var ckData: Data? = nil
    let id: String
    let clipboardItemId: String
    let typeIdentifier: String
    let data: Data
    let timestamp: Date
    let updatedDate: Date
    let isRemoved: Bool
    let cloudKitRecordID: String?
    
    static var recordType: String { "ClipboardItemContent" }
    
    var recordKeys: [String: CKRecordValue] {
        var keys: [String: CKRecordValue] = [
            RecordKeys.ClipboardItemContent.id.rawValue: id as NSString,
            RecordKeys.ClipboardItemContent.clipboardItemId.rawValue: clipboardItemId as NSString,
            RecordKeys.ClipboardItemContent.typeIdentifier.rawValue: typeIdentifier as NSString,
            RecordKeys.ClipboardItemContent.timestamp.rawValue: timestamp as NSDate,
            RecordKeys.ClipboardItemContent.updatedDate.rawValue: updatedDate as NSDate,
            RecordKeys.ClipboardItemContent.isRemoved.rawValue: isRemoved as NSNumber
        ]
        
        // Add parent reference
        let parentRecordID = CKRecord.ID(recordName: clipboardItemId, zoneID: SyncConstants.customZoneID)
        keys[RecordKeys.ClipboardItemContent.parent.rawValue] = CKRecord.Reference(
            recordID: parentRecordID,
            action: .none
        )
        
        if data.count > 1_000_000 { // 1MB threshold
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            do {
                try data.write(to: tempURL)
            } catch {
                
            }
            let asset = CKAsset(fileURL: tempURL)
            keys[RecordKeys.ClipboardItemContent.data.rawValue] = asset
        } else {
            keys[RecordKeys.ClipboardItemContent.data.rawValue] = data as NSData
        }
        
        return keys
    }
}

// MARK: - ClipboardItemContent Extensions
extension ClipboardItemContent {
    init(managedObject: ClipboardItemContentMO) {
        self.id = managedObject.id ?? ""
        self.clipboardItemId = managedObject.clipboardItemId ?? ""
        self.typeIdentifier = managedObject.typeIdentifier ?? ""
        self.data = managedObject.data ?? Data()
        self.timestamp = managedObject.timestamp ?? Date()
        self.updatedDate = managedObject.updatedDate ?? Date()
        self.isRemoved = managedObject.isRemoved
        self.cloudKitRecordID = managedObject.cloudKitRecordID
    }
    
    func record() -> CKRecord {
        CKRecord(self)
    }
    
    init?(from record: CKRecord) {
        guard
            let id = record[RecordKeys.ClipboardItemContent.id] as? String,
            let clipboardItemId = record[RecordKeys.ClipboardItemContent.clipboardItemId] as? String,
            let typeIdentifier = record[RecordKeys.ClipboardItemContent.typeIdentifier] as? String,
            let data = record[RecordKeys.ClipboardItemContent.data] as? Data,
            let timestamp = record[RecordKeys.ClipboardItemContent.timestamp] as? Date,
            let updatedDate = record[RecordKeys.ClipboardItemContent.updatedDate] as? Date,
            let isRemoved = record[RecordKeys.ClipboardItemContent.isRemoved] as? Bool
        else { return nil }
        
        self.id = id
        self.clipboardItemId = clipboardItemId
        self.typeIdentifier = typeIdentifier
        self.data = data
        self.timestamp = timestamp
        self.updatedDate = updatedDate
        self.isRemoved = isRemoved
        self.cloudKitRecordID = record.recordID.recordName
    }
}

// MARK: - ClipboardItem
extension ClipboardItem: Syncable {
    func record() -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: SyncConstants.customZoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        recordKeys.forEach { record[$0] = $1 }
        return record
    }
    
    init(record: CKRecord) throws {
        self.id = record.recordID.recordName
        self.ckData = record.encodedSystemFields
        
        guard
            let timestamp = record[RecordKeys.ClipboardItem.timestamp] as? Date,
            let updatedDate = record[RecordKeys.ClipboardItem.updatedDate] as? Date,
            let isRemoved = record[RecordKeys.ClipboardItem.isRemoved] as? Bool
        else {
            throw NSError(domain: "ClipboardItem", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid record data"])
        }
        
        self.timestamp = timestamp
        self.updatedDate = updatedDate
        self.isRemoved = isRemoved
        self.cloudKitRecordID = record.recordID.recordName
        self.contents = [] // Contents will be populated separately
    }
    
    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
        guard
            let clientDate = clientRecord[RecordKeys.ClipboardItem.updatedDate] as? Date,
            let serverDate = serverRecord[RecordKeys.ClipboardItem.updatedDate] as? Date
        else {
            return serverRecord
        }
        
        return clientDate > serverDate ? clientRecord : serverRecord
    }
}

extension ClipboardItemContent: Syncable {

    init(record: CKRecord) throws {
        self.id = record.recordID.recordName
        self.ckData = record.encodedSystemFields
        
        guard
            let clipboardItemId = record[RecordKeys.ClipboardItemContent.clipboardItemId] as? String,
            let data = record[RecordKeys.ClipboardItemContent.data] as? Data,
            let typeIdentifier = record[RecordKeys.ClipboardItemContent.typeIdentifier] as? String,
            let timestamp = record[RecordKeys.ClipboardItemContent.timestamp] as? Date,
            let updatedDate = record[RecordKeys.ClipboardItemContent.updatedDate] as? Date,
            let isRemoved = record[RecordKeys.ClipboardItemContent.isRemoved] as? Bool
        else {
            throw NSError(domain: "ClipboardItemContent", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid record data"])
        }
        
        self.clipboardItemId = clipboardItemId
        self.timestamp = timestamp
        self.updatedDate = updatedDate
        self.isRemoved = isRemoved
        self.typeIdentifier = typeIdentifier
        self.data = data
        self.cloudKitRecordID = record.recordID.recordName
    }
    
    static func resolveConflict(clientRecord: CKRecord, serverRecord: CKRecord) -> CKRecord {
        guard
            let clientDate = clientRecord[RecordKeys.ClipboardItemContent.updatedDate] as? Date,
            let serverDate = serverRecord[RecordKeys.ClipboardItemContent.updatedDate] as? Date
        else {
            return serverRecord
        }
        
        return clientDate > serverDate ? clientRecord : serverRecord
    }
}
